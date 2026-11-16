#pragma once

#include <atomic>
#include <csignal>
#include <cstdint>
#include <memory>
#include <string>
#include <span>
#include <vector>

#include <nlohmann/json.hpp>
#include <ylt/coro_http/coro_http_server.hpp>

#include "kv_store_client.hpp"
#include "perf_collector.h"
#include "zerocopy_buffer_manager.hpp"

namespace mooncake::tools {

/// @brief HTTP service for KVStore performance testing.
/// @note Provides RESTful API for put/get/exist operations and performance monitoring.
class HttpKVService {
   public:
    /// @brief Constructs a new HttpKVService.
    /// @param http_host HTTP listen host.
    /// @param http_port HTTP listen port.
    /// @param local_hostname This node's address for cluster communication.
    /// @param metadata_server Metadata server endpoint (URL or "P2PHANDSHAKE").
    /// @param global_segment_size Segment size (bytes) contributed to cluster
    ///        (0 = contribute nothing).
    /// @param local_buffer_size Local staging buffer size in bytes.
    /// @param protocol Transport protocol ("rdma" or "tcp").
    /// @param rdma_devices RDMA device names (empty = auto-select).
    /// @param master_server_addr Master service address.
    /// @param min_put_size_mb Minimum allowed payload size (MB) for put / batch_put.
    /// @param max_put_size_mb Maximum allowed payload size (MB) for put / batch_put.
    /// @param enable_zerocopy Enable zero-copy mode.
    /// @param zerocopy_recv_pool_size_mb Zero-copy receive pool size in MB.
    /// @param http_threads Number of HTTP server worker threads.
    /// @note The zero-copy send buffer is sized to max_put_size_mb, so it always
    ///       covers any legal put value.
    explicit HttpKVService(std::string http_host, std::uint16_t http_port,
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
                           std::size_t http_threads);

    /// @brief Destroys the HttpKVService.
    ~HttpKVService();

    HttpKVService(const HttpKVService&) = delete;
    HttpKVService& operator=(const HttpKVService&) = delete;

    /// @brief Starts the HTTP server.
    /// @param error_message Output parameter for error message.
    /// @return true on success, false on failure.
    bool Start(std::string& error_message);

    /// @brief Stops the HTTP server.
    void Stop();

    /// @brief Checks if the server is running.
    /// @return true if running, false otherwise.
    [[nodiscard]] bool IsRunning() const { return running_; }

   private:
    /// @brief Registers all HTTP routes.
    void RegisterRoutes();

    /// @brief Handles health check requests.
    /// @param req HTTP request.
    /// @param resp HTTP response.
    void HandleHealth(coro_http::coro_http_request& req,
                      coro_http::coro_http_response& resp);

    /// @brief Handles KV store operations.
    /// @param req HTTP request.
    /// @param resp HTTP response.
    void HandleKVOperation(coro_http::coro_http_request& req,
                           coro_http::coro_http_response& resp);

    /// @brief Handles performance data requests.
    /// @param req HTTP request.
    /// @param resp HTTP response.
    void HandlePerformance(coro_http::coro_http_request& req,
                           coro_http::coro_http_response& resp);

    /// @brief Handles reset requests.
    /// @param req HTTP request.
    /// @param resp HTTP response.
    void HandleReset(coro_http::coro_http_request& req,
                     coro_http::coro_http_response& resp);

    /// @brief Writes a JSON response.
    /// @param resp HTTP response.
    /// @param status HTTP status code.
    /// @param body JSON body.
    void WriteJson(coro_http::coro_http_response& resp,
                   coro_http::status_type status, const nlohmann::json& body);

    /// @brief Writes an error response.
    /// @param resp HTTP response.
    /// @param status HTTP status code.
    /// @param message Error message.
    void WriteError(coro_http::coro_http_response& resp,
                    coro_http::status_type status, const std::string& message);

    /// @brief Converts a performance report to JSON.
    /// @param report Performance report.
    /// @return JSON value.
    static nlohmann::json ReportToJson(const PerfCollector::Report& report);

    /// @brief Parses keys from a comma-separated string.
    /// @param keys_str Comma-separated keys.
    /// @return Vector of keys.
    static std::vector<std::string> ParseKeys(const std::string& keys_str);

    /// @brief Prepares the random value cache used for put/batch_put.
    void InitRandomValueCache();

    /// @brief Gets read-only prefix view from the cached random value.
    /// @param size Number of bytes to take from the front.
    /// @return Read-only span pointing into the cache.
    [[nodiscard]] std::span<const char> RandomValuePrefix(std::size_t size) const;

    /// @brief Gets the expected data prefix for verification, matching what
    ///        `put` actually wrote. In zero-copy mode this is the zero-copy
    ///        send buffer; otherwise the random value cache. Returns nullptr if
    ///        the requested size exceeds the available source buffer.
    /// @param size Number of bytes to compare from the front.
    /// @return Read-only pointer to the expected data, or nullptr on overflow.
    [[nodiscard]] const char* ExpectedDataPrefix(std::size_t size) const;

    std::string http_host_;
    std::uint16_t http_port_;
    std::string local_hostname_;
    std::string metadata_server_;
    std::size_t global_segment_size_;
    std::string protocol_;
    std::string rdma_devices_;
    std::string master_server_addr_;
    std::size_t local_buffer_size_;
    double min_put_size_mb_;
    double max_put_size_mb_;

    std::size_t max_value_bytes_{0};
    std::string random_value_cache_;

    std::unique_ptr<KvStoreClient> client_;
    std::unique_ptr<PerfCollector> perf_collector_;
    std::unique_ptr<ZeroCopyBufferManager> zerocopy_manager_;
    bool enable_zerocopy_;

    coro_http::coro_http_server server_;
    std::atomic<bool> running_{false};
};

}  // namespace mooncake::tools
