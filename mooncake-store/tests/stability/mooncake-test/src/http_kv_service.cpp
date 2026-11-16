#include "http_kv_service.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <span>

#include <glog/logging.h>

namespace mooncake::tools {

namespace {

/// @brief Default compression factor for t-digest.
constexpr double kDefaultCompression = 200.0;

/// @brief Default local buffer size (256MB).
constexpr std::size_t kDefaultLocalBufferSize = 256 * 1024 * 1024;

/// @brief Result of JSON field parsing.
enum class JsonFieldStatus {
    kNotFound,       ///< Field does not exist
    kTypeMismatch,   ///< Field exists but type is wrong
    kOk              ///< Field exists and type is correct
};

/// @brief Gets a string value from JSON and reports parsing status.
/// @param j JSON object
/// @param key Field name
/// @param status Output parameter for parsing status
/// @return The string value if successful, empty string otherwise
std::string GetJsonString(const nlohmann::json& j, const char* key,
                          JsonFieldStatus& status) {
    const auto it = j.find(key);
    if (it == j.end()) {
        status = JsonFieldStatus::kNotFound;
        return {};
    }
    if (!it->is_string()) {
        status = JsonFieldStatus::kTypeMismatch;
        return {};
    }
    status = JsonFieldStatus::kOk;
    return it->get<std::string>();
}

/// @brief Gets a string value from JSON (legacy overload, returns empty string on error).
/// @param j JSON object
/// @param key Field name
/// @param default_v Default value if field not found or type mismatch
/// @return The string value if successful, default_v otherwise
std::string GetJsonString(const nlohmann::json& j, const char* key,
                          const std::string& default_v = {}) {
    const auto it = j.find(key);
    if (it == j.end() || !it->is_string()) {
        return default_v;
    }
    return it->get<std::string>();
}

double ParseRequestSizeMb(const nlohmann::json& j, double default_mb) {
    const auto it = j.find("size");
    if (it == j.end() || it->is_null()) {
        return default_mb;
    }
    if (it->is_number_integer() || it->is_number_float()) {
        return it->get<double>();
    }
    if (it->is_string()) {
        return std::stod(it->get<std::string>());
    }
    throw std::invalid_argument("size must be a number or a numeric string");
}

std::string BoundErrorMessage(double min_mb, double max_mb) {
    return "size must be between " + std::to_string(min_mb) + " and " +
           std::to_string(max_mb) + " MB (inclusive)";
}

}  // namespace

HttpKVService::HttpKVService(std::string http_host, std::uint16_t http_port,
                             const std::string& local_hostname,
                             const std::string& metadata_server,
                             std::size_t global_segment_size,
                             std::size_t local_buffer_size,
                             const std::string& protocol,
                             const std::string& rdma_devices,
                             const std::string& master_server_addr,
                             double min_put_size_mb, double max_put_size_mb,
                             bool enable_zerocopy,
                             double zerocopy_recv_pool_size_mb,
                             std::size_t http_threads)
    : http_host_(std::move(http_host)),
      http_port_(http_port),
      local_hostname_(local_hostname),
      metadata_server_(metadata_server),
      global_segment_size_(global_segment_size),
      protocol_(protocol),
      rdma_devices_(rdma_devices),
      master_server_addr_(master_server_addr),
      local_buffer_size_(
          local_buffer_size > 0 ? local_buffer_size : kDefaultLocalBufferSize),
      min_put_size_mb_(min_put_size_mb),
      max_put_size_mb_(max_put_size_mb),
      client_(std::make_unique<KvStoreClient>()),
      perf_collector_(std::make_unique<PerfCollector>(kDefaultCompression)),
      zerocopy_manager_(nullptr),
      enable_zerocopy_(enable_zerocopy),
      server_(http_threads > 0 ? http_threads : 1, http_port_, http_host_) {

    // Initialize zero-copy manager if enabled
    if (enable_zerocopy_) {
        // The send buffer is sized to the maximum allowed put size so it always
        // covers any legal put / batch_put value (no separate config needed).
        const std::size_t max_put_bytes = static_cast<std::size_t>(
            std::llround(max_put_size_mb_ * 1024.0 * 1024.0));
        const std::size_t send_size = max_put_bytes;
        const std::size_t recv_pool_size = static_cast<std::size_t>(
            std::llround(zerocopy_recv_pool_size_mb * 1024.0 * 1024.0));

        zerocopy_manager_ = std::make_unique<ZeroCopyBufferManager>(
            send_size, recv_pool_size);

        // Warn if the recv pool cannot even hold the largest object; such gets
        // fail hard (503, no fallback).
        if (recv_pool_size < max_put_bytes) {
            LOG(WARNING) << "zerocopy-recv-pool-size-mb ("
                         << zerocopy_recv_pool_size_mb << ") < max-put-size-mb ("
                         << max_put_size_mb_
                         << "); gets of the largest object cannot be served (503)";
        }
    }
}

HttpKVService::~HttpKVService() { Stop(); }

bool HttpKVService::Start(std::string& error_message) {
    const int rc = client_->Setup(local_hostname_, metadata_server_,
                                   global_segment_size_, local_buffer_size_,
                                   protocol_, rdma_devices_, master_server_addr_);
    if (rc != 0) {
        error_message = "Failed to setup KV store client with error code: " +
                        std::to_string(rc);
        LOG(ERROR) << error_message;
        return false;
    }

    try {
        InitRandomValueCache();
    } catch (const std::exception& e) {
        error_message = std::string("Failed to init random value cache: ") +
                        e.what();
        LOG(ERROR) << error_message;
        return false;
    }

    // Register zero-copy buffers if enabled
    if (enable_zerocopy_ && zerocopy_manager_) {
        try {
            // Register send buffer
            void* send_buf = zerocopy_manager_->GetSendBuffer(0);
            std::size_t send_size = zerocopy_manager_->GetSendBufferSize();
            int rc = client_->RegisterBuffer(send_buf, send_size);
            if (rc != 0) {
                error_message = "Failed to register zero-copy send buffer: " +
                                std::to_string(rc);
                LOG(ERROR) << error_message;
                return false;
            }
            LOG(INFO) << "Registered zero-copy send buffer: "
                      << (send_size / 1024 / 1024) << " MB";

            // Register the whole receive pool once. Registration is persistent
            // (keyed by physical address for the buffer's lifetime); the offset
            // allocator then sub-allocates regions within this registered pool.
            void* recv_pool = zerocopy_manager_->GetRecvPoolBase();
            const std::size_t recv_pool_size =
                zerocopy_manager_->GetRecvPoolSize();
            rc = client_->RegisterBuffer(recv_pool, recv_pool_size);
            if (rc != 0) {
                error_message =
                    "Failed to register zero-copy recv pool: " +
                    std::to_string(rc);
                LOG(ERROR) << error_message;
                return false;
            }
            LOG(INFO) << "Registered zero-copy recv pool: "
                      << (recv_pool_size / 1024 / 1024) << " MB";
        } catch (const std::exception& e) {
            error_message = std::string("Failed to register zero-copy buffers: ") +
                            e.what();
            LOG(ERROR) << error_message;
            return false;
        }
    }

    RegisterRoutes();
    server_.set_max_http_body_size(
        static_cast<int64_t>(std::numeric_limits<int32_t>::max()));

    auto ec = server_.async_start();
    ec.wait();
    const auto start_error = ec.value();
    if (start_error) {
        error_message = start_error.message();
        LOG(ERROR) << "Failed to start HTTP server: " << error_message;
        return false;
    }

    running_ = true;
    LOG(INFO) << "HTTP KV service started on " << http_host_ << ":" << http_port_
              << ", local_hostname=" << local_hostname_
              << ", metadata_server=" << metadata_server_
              << ", master_server_addr=" << master_server_addr_
              << ", protocol=" << protocol_
              << ", global_segment_size=" << global_segment_size_
              << ", put size bounds [" << min_put_size_mb_ << ", "
              << max_put_size_mb_ << "] MB";
    return true;
}

void HttpKVService::Stop() {
    if (!running_) {
        return;
    }

    server_.stop();
    running_ = false;

    // NOTE: This test tool runs as a container-scoped "test role"; its lifetime
    // equals the container's. The only graceful exit path is SIGTERM/SIGINT,
    // which RealClient's ResourceTracker handles by running tearDownAll()
    // (metadata cleanup) and re-raising to terminate the process -- it does not
    // return through here. SIGKILL cannot clean up at all. Endpoint-reuse
    // conflicts after a crash are avoided instead by NOT pinning a port in
    // --local-hostname, which lets Mooncake auto-pick a free port and retry on
    // metadata conflict. So no explicit unregister/teardown is needed here.
    LOG(INFO) << "HTTP KV service stopped";
}

void HttpKVService::InitRandomValueCache() {
    // Compute byte size using the same rounding logic as request handling.
    max_value_bytes_ = static_cast<std::size_t>(
        std::llround(max_put_size_mb_ * 1024.0 * 1024.0));

    if (max_value_bytes_ == 0) {
        throw std::invalid_argument("max_put_size_mb rounds to zero bytes");
    }

    random_value_cache_.resize(max_value_bytes_);

    // Generate once at startup; subsequent requests only take read-only
    // prefixes from this buffer.
    std::mt19937_64 gen(
        std::chrono::steady_clock::now().time_since_epoch().count());
    std::uniform_int_distribution<> dist(0, 255);

    for (std::size_t i = 0; i < max_value_bytes_; ++i) {
        random_value_cache_[i] = static_cast<char>(dist(gen));
    }

    LOG(INFO) << "Random value cache initialized: " << max_value_bytes_
              << " bytes";
}

std::span<const char> HttpKVService::RandomValuePrefix(std::size_t size) const {
    if (size == 0) {
        return {};
    }
    if (size > random_value_cache_.size()) {
        throw std::out_of_range("RandomValuePrefix size exceeds cache size");
    }
    return std::span<const char>(random_value_cache_.data(), size);
}

const char* HttpKVService::ExpectedDataPrefix(std::size_t size) const {
    // Return the exact source buffer that `put` wrote from, so verification
    // compares against the correct bytes:
    //   - Zero-copy: put_from reads the zero-copy send buffer (its own random
    //     fill, distinct from random_value_cache_).
    //   - Regular:   put reads a prefix of random_value_cache_.
    if (enable_zerocopy_ && zerocopy_manager_) {
        if (size > zerocopy_manager_->GetSendBufferSize()) {
            return nullptr;
        }
        // GetSendBuffer returns the buffer base (immutable after construction).
        return static_cast<const char*>(zerocopy_manager_->GetSendBuffer(size));
    }
    if (size > random_value_cache_.size()) {
        return nullptr;
    }
    return random_value_cache_.data();
}

void HttpKVService::RegisterRoutes() {
    using namespace coro_http;

    server_.set_http_handler<GET>(
        "/health",
        [this](coro_http_request& req, coro_http_response& resp) {
            HandleHealth(req, resp);
        });

    server_.set_http_handler<POST>(
        "/api/kv",
        [this](coro_http_request& req, coro_http_response& resp) {
            HandleKVOperation(req, resp);
        });

    server_.set_http_handler<GET>(
        "/api/performance",
        [this](coro_http_request& req, coro_http_response& resp) {
            HandlePerformance(req, resp);
        });

    server_.set_http_handler<POST>(
        "/api/reset",
        [this](coro_http_request& req, coro_http_response& resp) {
            HandleReset(req, resp);
        });
}

void HttpKVService::HandleHealth(coro_http::coro_http_request&,
                                 coro_http::coro_http_response& resp) {
    const int health_code = client_->HealthCheck();

    nlohmann::json body;
    body["ready"] = (health_code == mooncake::HC_HEALTHY);
    body["status"] = [health_code]() {
        switch (health_code) {
            case mooncake::HC_HEALTHY:
                return "healthy";
            case mooncake::HC_NOT_INITIALIZED:
                return "not_initialized";
            case mooncake::HC_MASTER_UNREACHABLE:
                return "master_unreachable";
            default:
                return "unknown";
        }
    }();
    body["local_hostname"] = local_hostname_;
    body["metadata_server"] = metadata_server_;
    body["master_server_addr"] = master_server_addr_;
    body["protocol"] = protocol_;
    body["global_segment_size"] = global_segment_size_;

    WriteJson(resp,
              health_code == mooncake::HC_HEALTHY
                  ? coro_http::status_type::ok
                  : coro_http::status_type::service_unavailable,
              body);
}

void HttpKVService::HandleKVOperation(coro_http::coro_http_request& req,
                                      coro_http::coro_http_response& resp) {
    const auto body_view = req.get_body();
    if (body_view.empty()) {
        WriteError(resp, coro_http::status_type::bad_request,
                   "Request body must not be empty");
        return;
    }

    nlohmann::json json_body;
    try {
        json_body = nlohmann::json::parse(body_view);
    } catch (const nlohmann::json::exception& e) {
        WriteError(resp, coro_http::status_type::bad_request,
                   std::string("Invalid JSON: ") + e.what());
        return;
    }

    JsonFieldStatus operator_status;
    const auto operator_type = GetJsonString(json_body, "operator", operator_status);
    if (operator_status == JsonFieldStatus::kNotFound) {
        WriteError(resp, coro_http::status_type::bad_request,
                   "operator is required");
        return;
    }
    if (operator_status == JsonFieldStatus::kTypeMismatch) {
        WriteError(resp, coro_http::status_type::bad_request,
                   "operator must be a string");
        return;
    }
    if (operator_type.empty()) {
        WriteError(resp, coro_http::status_type::bad_request,
                   "operator must not be empty");
        return;
    }

    if (operator_type == "put") {
        JsonFieldStatus key_status;
        const auto key = GetJsonString(json_body, "key", key_status);
        if (key_status == JsonFieldStatus::kNotFound || key_status == JsonFieldStatus::kTypeMismatch) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must be a string");
            return;
        }
        if (key.empty()) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must not be empty");
            return;
        }

        double size_mb = 0.0;
        try {
            size_mb = ParseRequestSizeMb(json_body, 1.0);
        } catch (const std::exception& e) {
            WriteError(resp, coro_http::status_type::bad_request,
                       std::string("Invalid size: ") + e.what());
            return;
        }

        if (size_mb < min_put_size_mb_ || size_mb > max_put_size_mb_) {
            WriteError(resp, coro_http::status_type::bad_request,
                       BoundErrorMessage(min_put_size_mb_, max_put_size_mb_));
            return;
        }

        const std::size_t value_bytes = static_cast<std::size_t>(
            std::llround(size_mb * 1024.0 * 1024.0));
        if (value_bytes == 0) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "size rounds to zero bytes");
            return;
        }

        int result_code = 0;
        double rpc_latency = 0.0;

        if (enable_zerocopy_ && zerocopy_manager_) {
            // Zero-copy path.
            void* send_buffer = zerocopy_manager_->GetSendBuffer(value_bytes);
            if (!send_buffer) {
                // Value exceeds the send buffer: hard fail, no fallback, so
                // put_from latency stays purely zero-copy.
                WriteError(resp, coro_http::status_type::service_unavailable,
                           "value exceeds zero-copy send buffer size");
                return;
            }
            PerfTimer timer;
            result_code = client_->PutFrom(key, send_buffer, value_bytes);
            rpc_latency = timer.ElapsedMs();
            perf_collector_->Record("put_from", rpc_latency);
        } else {
            // Regular path.
            const auto value_span = RandomValuePrefix(value_bytes);
            PerfTimer timer;
            result_code = client_->Put(key, value_span);
            rpc_latency = timer.ElapsedMs();
            perf_collector_->Record("put", rpc_latency);
        }

        nlohmann::json result;
        result["operator"] = operator_type;
        result["key"] = key;
        result["code"] = result_code;
        result["duration_ms"] = rpc_latency;
        result["size_mb"] = size_mb;
        result["value_bytes"] = value_bytes;
        result["zerocopy"] = enable_zerocopy_;
        WriteJson(resp, coro_http::status_type::ok, result);

    } else if (operator_type == "get") {
        JsonFieldStatus key_status;
        const auto key = GetJsonString(json_body, "key", key_status);
        if (key_status == JsonFieldStatus::kNotFound || key_status == JsonFieldStatus::kTypeMismatch) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must be a string");
            return;
        }
        if (key.empty()) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must not be empty");
            return;
        }

        // Check if data verification is requested
        bool verify_data = false;
        if (json_body.contains("verify_data") && json_body["verify_data"].is_boolean()) {
            verify_data = json_body["verify_data"].get<bool>();
        }

        int result_code = 0;
        double rpc_latency = 0.0;
        std::size_t bytes_read = 0;
        const char* data_ptr = nullptr;  // For data verification

        if (enable_zerocopy_ && zerocopy_manager_) {
            // Zero-copy path. Allocate a receive region from the pool. The
            // request may carry an optional "size" (MB) hint for how large a
            // region to reserve; otherwise reserve max_put_size_mb_.
            double size_mb = max_put_size_mb_;
            try {
                size_mb = ParseRequestSizeMb(json_body, max_put_size_mb_);
            } catch (const std::exception& e) {
                WriteError(resp, coro_http::status_type::bad_request,
                           std::string("Invalid size: ") + e.what());
                return;
            }
            const std::size_t want = static_cast<std::size_t>(
                std::llround(size_mb * 1024.0 * 1024.0));

            // Time the recv-pool allocation together with the RPC so this path
            // measures the same logical scope as the regular path below, which
            // times client_->Get (internal buffer allocation + RPC + copy).
            // Excluding the allocation here would understate zero-copy latency
            // and make the zero-copy vs regular comparison unfair. The genuine
            // zero-copy advantage (no memcpy) is still reflected because GetInto
            // reads directly into the pool region.
            PerfTimer timer;
            auto handle = zerocopy_manager_->AllocateRecv(want);
            if (!handle) {
                // Pool exhausted / too fragmented: hard fail, no fallback.
                WriteError(resp, coro_http::status_type::service_unavailable,
                           "zero-copy recv pool exhausted");
                return;
            }
            int64_t result = client_->GetInto(key, handle->ptr(), want);
            rpc_latency = timer.ElapsedMs();

            if (result >= 0) {
                bytes_read = static_cast<std::size_t>(result);
                result_code = 0;
                data_ptr = static_cast<const char*>(handle->ptr());
            } else {
                result_code = -1;
            }
            perf_collector_->Record("get_into", rpc_latency);

            // Perform data verification if requested (before handle goes out of scope)
            bool data_valid = true;
            std::size_t mismatch_offset = 0;
            if (verify_data && result_code == 0 && bytes_read > 0) {
                const char* expected = ExpectedDataPrefix(bytes_read);
                if (expected == nullptr) {
                    // Received more data than the source buffer holds - fail.
                    data_valid = false;
                } else {
                    // Compare received data with expected source prefix
                    for (std::size_t i = 0; i < bytes_read; ++i) {
                        if (data_ptr[i] != expected[i]) {
                            data_valid = false;
                            mismatch_offset = i;
                            break;
                        }
                    }
                }
            }

            // Build result JSON
            nlohmann::json result_json;
            result_json["operator"] = operator_type;
            result_json["key"] = key;
            result_json["code"] = result_code;
            result_json["size"] = bytes_read;
            result_json["duration_ms"] = rpc_latency;
            result_json["zerocopy"] = enable_zerocopy_;
            if (verify_data && result_code == 0) {
                result_json["data_valid"] = data_valid;
                if (!data_valid) {
                    result_json["mismatch_offset"] = mismatch_offset;
                }
            }
            WriteJson(resp, coro_http::status_type::ok, result_json);
            // handle goes out of scope here -> region returned to pool (untimed)
        } else {
            // Regular path.
            std::string value;
            PerfTimer timer;
            result_code = client_->Get(key, value);
            rpc_latency = timer.ElapsedMs();
            bytes_read = value.size();
            perf_collector_->Record("get", rpc_latency);

            // Perform data verification if requested
            bool data_valid = true;
            std::size_t mismatch_offset = 0;
            if (verify_data && result_code == 0 && bytes_read > 0) {
                const char* expected = ExpectedDataPrefix(bytes_read);
                if (expected == nullptr) {
                    // Received more data than the source buffer holds - fail.
                    data_valid = false;
                } else {
                    // Compare received data with expected source prefix
                    for (std::size_t i = 0; i < bytes_read; ++i) {
                        if (value[i] != expected[i]) {
                            data_valid = false;
                            mismatch_offset = i;
                            break;
                        }
                    }
                }
            }

            nlohmann::json result;
            result["operator"] = operator_type;
            result["key"] = key;
            result["code"] = result_code;
            result["size"] = bytes_read;
            result["duration_ms"] = rpc_latency;
            result["zerocopy"] = enable_zerocopy_;
            if (verify_data && result_code == 0) {
                result["data_valid"] = data_valid;
                if (!data_valid) {
                    result["mismatch_offset"] = mismatch_offset;
                }
            }
            WriteJson(resp, coro_http::status_type::ok, result);
        }

    } else if (operator_type == "exist") {
        JsonFieldStatus key_status;
        const auto key = GetJsonString(json_body, "key", key_status);
        if (key_status == JsonFieldStatus::kNotFound || key_status == JsonFieldStatus::kTypeMismatch) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must be a string");
            return;
        }
        if (key.empty()) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must not be empty");
            return;
        }

        // Start timing only for RPC call
        PerfTimer timer;
        const int exists = client_->Exist(key);
        const double rpc_latency = timer.ElapsedMs();

        perf_collector_->Record("exist", rpc_latency);

        nlohmann::json result;
        result["operator"] = operator_type;
        result["key"] = key;
        result["exists"] = (exists == 1);
        result["code"] = exists;
        result["duration_ms"] = rpc_latency;
        WriteJson(resp, coro_http::status_type::ok, result);

    } else if (operator_type == "batch_put") {
        JsonFieldStatus keys_str_status;
        const auto keys_str = GetJsonString(json_body, "key", keys_str_status);
        if (keys_str_status == JsonFieldStatus::kNotFound || keys_str_status == JsonFieldStatus::kTypeMismatch) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key (comma-separated string) is required for batch_put");
            return;
        }
        if (keys_str.empty()) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must not be empty");
            return;
        }

        double size_mb = 0.0;
        try {
            size_mb = ParseRequestSizeMb(json_body, 1.0);
        } catch (const std::exception& e) {
            WriteError(resp, coro_http::status_type::bad_request,
                       std::string("Invalid size: ") + e.what());
            return;
        }

        if (size_mb < min_put_size_mb_ || size_mb > max_put_size_mb_) {
            WriteError(resp, coro_http::status_type::bad_request,
                       BoundErrorMessage(min_put_size_mb_, max_put_size_mb_));
            return;
        }

        const std::size_t value_bytes = static_cast<std::size_t>(
            std::llround(size_mb * 1024.0 * 1024.0));
        if (value_bytes == 0) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "size rounds to zero bytes");
            return;
        }

        const auto keys = ParseKeys(keys_str);
        const auto value_span = RandomValuePrefix(value_bytes);

        double rpc_latency = 0.0;
        std::vector<int> results;

        if (enable_zerocopy_ && zerocopy_manager_) {
            // Zero-copy path. All keys share the single read-only send buffer.
            void* send_buffer = zerocopy_manager_->GetSendBuffer(value_bytes);
            if (!send_buffer) {
                WriteError(resp, coro_http::status_type::service_unavailable,
                           "value exceeds zero-copy send buffer size");
                return;
            }
            std::vector<void*> buffers(keys.size(), send_buffer);
            std::vector<std::size_t> sizes(keys.size(), value_bytes);

            PerfTimer timer;
            results = client_->BatchPutFrom(keys, buffers, sizes);
            rpc_latency = timer.ElapsedMs();
            perf_collector_->Record("batch_put_from", rpc_latency);
        } else {
            // Regular path.
            PerfTimer timer;
            results = client_->BatchPut(keys, value_span);
            rpc_latency = timer.ElapsedMs();
            perf_collector_->Record("batch_put", rpc_latency);
        }

        nlohmann::json result;
        result["operator"] = operator_type;
        result["keys"] = nlohmann::json::array();
        result["total"] = keys.size();
        result["success"] = static_cast<std::size_t>(
            std::count(results.begin(), results.end(), 0));
        result["duration_ms"] = rpc_latency;
        result["size_mb"] = size_mb;
        result["value_bytes"] = value_bytes;
        result["zerocopy"] = enable_zerocopy_;
        for (const auto& k : keys) {
            result["keys"].push_back(k);
        }
        WriteJson(resp, coro_http::status_type::ok, result);

    } else if (operator_type == "batch_get") {
        JsonFieldStatus keys_str_status;
        const auto keys_str = GetJsonString(json_body, "key", keys_str_status);
        if (keys_str_status == JsonFieldStatus::kNotFound || keys_str_status == JsonFieldStatus::kTypeMismatch) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key (comma-separated string) is required for batch_get");
            return;
        }
        if (keys_str.empty()) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must not be empty");
            return;
        }

        // Check if data verification is requested
        bool verify_data = false;
        if (json_body.contains("verify_data") && json_body["verify_data"].is_boolean()) {
            verify_data = json_body["verify_data"].get<bool>();
        }

        const auto keys = ParseKeys(keys_str);

        std::vector<int> results;
        double rpc_latency = 0.0;

        // For data verification
        std::vector<bool> validation_results;
        std::vector<std::size_t> mismatch_offsets;
        if (verify_data) {
            validation_results.resize(keys.size(), true);
            mismatch_offsets.resize(keys.size(), 0);
        }

        if (enable_zerocopy_ && zerocopy_manager_) {
            // Zero-copy path. Allocate one recv region per key; the optional
            // "size" (MB) hint sizes each region, else max_put_size_mb_.
            double size_mb = max_put_size_mb_;
            try {
                size_mb = ParseRequestSizeMb(json_body, max_put_size_mb_);
            } catch (const std::exception& e) {
                WriteError(resp, coro_http::status_type::bad_request,
                           std::string("Invalid size: ") + e.what());
                return;
            }
            const std::size_t want = static_cast<std::size_t>(
                std::llround(size_mb * 1024.0 * 1024.0));

            // Hold handles so regions stay reserved for the whole RPC; RAII
            // returns them to the pool when this vector goes out of scope.
            std::vector<mooncake::BufferHandle> handles;
            std::vector<void*> recv_buffers;
            std::vector<std::size_t> recv_sizes;
            handles.reserve(keys.size());
            recv_buffers.reserve(keys.size());
            recv_sizes.reserve(keys.size());

            // Time the recv-pool allocations together with the RPC so this path
            // measures the same logical scope as the regular batch_get path,
            // which times client_->BatchGet (batch_get_buffer + per-key copy).
            // The genuine zero-copy advantage (no per-key memcpy) is still
            // reflected because BatchGetInto reads directly into pool regions.
            PerfTimer timer;
            for (std::size_t i = 0; i < keys.size(); ++i) {
                auto handle = zerocopy_manager_->AllocateRecv(want);
                if (!handle) {
                    // Pool cannot satisfy the whole batch: hard fail, no
                    // fallback. Already-acquired handles free via RAII on return.
                    WriteError(resp, coro_http::status_type::service_unavailable,
                               "zero-copy recv pool exhausted for batch_get");
                    return;
                }
                recv_buffers.push_back(handle->ptr());
                recv_sizes.push_back(want);
                handles.push_back(std::move(*handle));
            }

            std::vector<int64_t> byte_results =
                client_->BatchGetInto(keys, recv_buffers, recv_sizes);
            rpc_latency = timer.ElapsedMs();

            for (auto bytes : byte_results) {
                results.push_back(bytes >= 0 ? 0 : -1);
            }
            perf_collector_->Record("batch_get_into", rpc_latency);

            // Perform data verification if requested (before handles go out of scope)
            if (verify_data) {
                for (std::size_t i = 0; i < keys.size(); ++i) {
                    if (byte_results[i] > 0) {
                        const std::size_t bytes_read = static_cast<std::size_t>(byte_results[i]);
                        const char* expected = ExpectedDataPrefix(bytes_read);
                        const char* data_ptr = static_cast<const char*>(recv_buffers[i]);

                        if (expected == nullptr) {
                            validation_results[i] = false;
                        } else {
                            for (std::size_t j = 0; j < bytes_read; ++j) {
                                if (data_ptr[j] != expected[j]) {
                                    validation_results[i] = false;
                                    mismatch_offsets[i] = j;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            // handles go out of scope here -> regions returned (untimed)
        } else {
            // Regular path.
            std::vector<std::string> values;
            PerfTimer timer;
            results = client_->BatchGet(keys, values);
            rpc_latency = timer.ElapsedMs();
            perf_collector_->Record("batch_get", rpc_latency);

            // Perform data verification if requested
            if (verify_data) {
                for (std::size_t i = 0; i < keys.size(); ++i) {
                    if (results[i] == 0 && i < values.size() && !values[i].empty()) {
                        const std::size_t bytes_read = values[i].size();
                        const char* expected = ExpectedDataPrefix(bytes_read);

                        if (expected == nullptr) {
                            validation_results[i] = false;
                        } else {
                            for (std::size_t j = 0; j < bytes_read; ++j) {
                                if (values[i][j] != expected[j]) {
                                    validation_results[i] = false;
                                    mismatch_offsets[i] = j;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        nlohmann::json result;
        result["operator"] = operator_type;
        result["keys"] = nlohmann::json::array();
        result["total"] = keys.size();
        result["success"] = static_cast<std::size_t>(
            std::count(results.begin(), results.end(), 0));
        result["duration_ms"] = rpc_latency;
        result["zerocopy"] = enable_zerocopy_;
        for (const auto& k : keys) {
            result["keys"].push_back(k);
        }

        // Add validation results if verification was requested
        if (verify_data) {
            bool all_valid = std::all_of(validation_results.begin(), validation_results.end(),
                                         [](bool v) { return v; });
            result["data_valid"] = all_valid;

            // Add detailed validation results
            nlohmann::json validation_details = nlohmann::json::array();
            for (std::size_t i = 0; i < keys.size(); ++i) {
                nlohmann::json detail;
                detail["key"] = keys[i];
                detail["valid"] = static_cast<bool>(validation_results[i]);
                if (!validation_results[i] && mismatch_offsets[i] > 0) {
                    detail["mismatch_offset"] = mismatch_offsets[i];
                }
                validation_details.push_back(detail);
            }
            result["validation_details"] = validation_details;
        }

        WriteJson(resp, coro_http::status_type::ok, result);

    } else if (operator_type == "batch_exist") {
        JsonFieldStatus keys_str_status;
        const auto keys_str = GetJsonString(json_body, "key", keys_str_status);
        if (keys_str_status == JsonFieldStatus::kNotFound || keys_str_status == JsonFieldStatus::kTypeMismatch) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key (comma-separated string) is required for batch_exist");
            return;
        }
        if (keys_str.empty()) {
            WriteError(resp, coro_http::status_type::bad_request,
                       "key must not be empty");
            return;
        }

        const auto keys = ParseKeys(keys_str);

        // Start timing only for RPC call
        PerfTimer timer;
        const auto results = client_->BatchExist(keys);
        const double rpc_latency = timer.ElapsedMs();

        perf_collector_->Record("batch_exist", rpc_latency);

        nlohmann::json result;
        result["operator"] = operator_type;
        result["keys"] = nlohmann::json::array();
        result["total"] = keys.size();
        result["exists"] = static_cast<std::size_t>(
            std::count(results.begin(), results.end(), 1));
        result["duration_ms"] = rpc_latency;
        for (const auto& k : keys) {
            result["keys"].push_back(k);
        }
        WriteJson(resp, coro_http::status_type::ok, result);

    } else {
        WriteError(resp, coro_http::status_type::bad_request,
                   "Unknown operator: " + operator_type);
    }
}

void HttpKVService::HandlePerformance(coro_http::coro_http_request&,
                                      coro_http::coro_http_response& resp) {
    const auto reports = perf_collector_->GetReports();

    nlohmann::json result = nlohmann::json::array();
    for (const auto& report : reports) {
        result.push_back(ReportToJson(report));
    }

    WriteJson(resp, coro_http::status_type::ok, result);
}

void HttpKVService::HandleReset(coro_http::coro_http_request&,
                                coro_http::coro_http_response& resp) {
    perf_collector_->Reset();

    nlohmann::json result;
    result["status"] = "reset_success";
    result["message"] = "Performance data has been reset";

    WriteJson(resp, coro_http::status_type::ok, result);
}

nlohmann::json HttpKVService::ReportToJson(const PerfCollector::Report& report) {
    nlohmann::json root;
    root["tag"] = report.tag;
    root["avgMs"] = report.avg_ms;
    root["minMs"] = report.min_ms;
    root["maxMs"] = report.max_ms;
    root["p90Ms"] = report.p90_ms;
    root["p95Ms"] = report.p95_ms;
    root["p99Ms"] = report.p99_ms;
    root["qps"] = report.qps;
    root["totalDurationMs"] = report.total_duration_ms;
    root["totalTimeSpanMs"] = report.total_time_span_ms;
    root["totalRequests"] = report.total_requests;
    return root;
}

void HttpKVService::WriteJson(coro_http::coro_http_response& resp,
                              coro_http::status_type status,
                              const nlohmann::json& body) {
    resp.add_header("Content-Type", "application/json; charset=utf-8");
    resp.set_status_and_content(status, body.dump());
}

void HttpKVService::WriteError(coro_http::coro_http_response& resp,
                               coro_http::status_type status,
                               const std::string& message) {
    nlohmann::json body;
    body["error"] = message;
    WriteJson(resp, status, body);
}

std::vector<std::string> HttpKVService::ParseKeys(const std::string& keys_str) {
    std::vector<std::string> keys;
    std::stringstream ss(keys_str);
    std::string key;
    while (std::getline(ss, key, ',')) {
        if (!key.empty()) {
            keys.push_back(key);
        }
    }
    return keys;
}

}  // namespace mooncake::tools
