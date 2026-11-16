#include "kv_store_client.hpp"

#include <span>

#include <glog/logging.h>

namespace mooncake::tools {

KvStoreClient::KvStoreClient() = default;

KvStoreClient::~KvStoreClient() = default;

int KvStoreClient::Setup(const std::string& local_hostname,
                         const std::string& metadata_server,
                         std::size_t global_segment_size,
                         std::size_t local_buffer_size,
                         const std::string& protocol,
                         const std::string& rdma_devices,
                         const std::string& master_server_addr) {
    client_ = mooncake::RealClient::create();
    const int rc = client_->setup_real(
        local_hostname, metadata_server, global_segment_size, local_buffer_size,
        protocol, rdma_devices, master_server_addr);
    if (rc != 0) {
        LOG(ERROR) << "Failed to setup RealClient: rc=" << rc;
        client_.reset();
        return rc;
    }
    LOG(INFO) << "KvStoreClient setup succeeded, local_hostname="
              << local_hostname << ", metadata_server=" << metadata_server
              << ", master_server_addr=" << master_server_addr
              << ", protocol=" << protocol
              << ", global_segment_size=" << global_segment_size;
    return 0;
}

int KvStoreClient::Put(const std::string& key, const std::string& value,
                       std::size_t replica_num) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    mooncake::ReplicateConfig config;
    config.replica_num = replica_num;

    const int rc = client_->put(key, std::span<const char>(value.data(), value.size()), config);
    if (rc != 0) {
        LOG(ERROR) << "Put failed, key=" << key << ", rc=" << rc;
    }
    return rc;
}

int KvStoreClient::Put(const std::string& key, std::span<const char> value,
                       std::size_t replica_num) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    mooncake::ReplicateConfig config;
    config.replica_num = replica_num;

    const int rc = client_->put(key, value, config);
    if (rc != 0) {
        LOG(ERROR) << "Put failed, key=" << key << ", rc=" << rc;
    }
    return rc;
}

int KvStoreClient::Get(const std::string& key, std::string& value) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    auto handle = client_->get_buffer(key);
    if (!handle) {
        VLOG(1) << "Get failed, key=" << key << ", not found";
        return -1;
    }

    value.assign(static_cast<const char*>(handle->ptr()), handle->size());
    handle.reset();
    return 0;
}

int KvStoreClient::Exist(const std::string& key) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    return client_->isExist(key);
}

std::vector<int> KvStoreClient::BatchPut(const std::vector<std::string>& keys,
                                         const std::vector<std::string>& values,
                                         std::size_t replica_num) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return std::vector<int>(keys.size(), -1);
    }

    if (keys.size() != values.size()) {
        LOG(ERROR) << "Keys and values size mismatch: keys=" << keys.size()
                   << ", values=" << values.size();
        return std::vector<int>(keys.size(), -1);
    }

    mooncake::ReplicateConfig config;
    config.replica_num = replica_num;

    // Convert std::string to std::span<const char>
    std::vector<std::span<const char>> value_spans;
    value_spans.reserve(values.size());
    for (const auto& value : values) {
        value_spans.emplace_back(value.data(), value.size());
    }

    // Use true batch RPC interface
    const int rc = client_->put_batch(keys, value_spans, config);

    // put_batch returns 0 on success for all, or error code
    std::vector<int> results(keys.size(), rc);
    if (rc != 0) {
        LOG(ERROR) << "Batch put failed, rc=" << rc;
    }

    return results;
}

std::vector<int> KvStoreClient::BatchPut(const std::vector<std::string>& keys,
                                          std::span<const char> value,
                                          std::size_t replica_num) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return std::vector<int>(keys.size(), -1);
    }

    mooncake::ReplicateConfig config;
    config.replica_num = replica_num;

    // All keys use the same value - construct value_spans vector
    std::vector<std::span<const char>> value_spans(keys.size(), value);

    // Use true batch RPC interface
    const int rc = client_->put_batch(keys, value_spans, config);

    // put_batch returns 0 on success for all, or error code
    std::vector<int> results(keys.size(), rc);
    if (rc != 0) {
        LOG(ERROR) << "Batch put failed, rc=" << rc;
    }

    return results;
}

std::vector<int> KvStoreClient::BatchGet(const std::vector<std::string>& keys,
                                         std::vector<std::string>& values) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return std::vector<int>(keys.size(), -1);
    }

    std::vector<int> results;
    results.reserve(keys.size());
    values.clear();
    values.reserve(keys.size());

    // Use true batch RPC interface
    auto handles = client_->batch_get_buffer(keys);

    for (size_t i = 0; i < keys.size(); ++i) {
        if (!handles[i]) {
            results.push_back(-1);
            values.emplace_back();
            continue;
        }

        values.emplace_back(static_cast<const char*>(handles[i]->ptr()), handles[i]->size());
        results.push_back(0);
    }

    return results;
}

std::vector<int> KvStoreClient::BatchExist(const std::vector<std::string>& keys) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return std::vector<int>(keys.size(), -1);
    }

    // Use true batch RPC interface
    return client_->batchIsExist(keys);
}

int KvStoreClient::Remove(const std::string& key) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    return client_->remove(key);
}

long KvStoreClient::RemoveByRegex(const std::string& regex, bool force) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    return client_->removeByRegex(regex, force);
}

long KvStoreClient::RemoveAll(bool force) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    return client_->removeAll(force);
}

int KvStoreClient::HealthCheck() {
    if (!client_) {
        return mooncake::HC_NOT_INITIALIZED;
    }
    return client_->health_check();
}

// Zero-copy interface implementations

int KvStoreClient::RegisterBuffer(void* buffer, std::size_t size) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    return client_->register_buffer(buffer, size);
}

int KvStoreClient::UnregisterBuffer(void* buffer) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    return client_->unregister_buffer(buffer);
}

int KvStoreClient::PutFrom(const std::string& key, void* buffer, std::size_t size,
                           std::size_t replica_num) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    mooncake::ReplicateConfig config;
    config.replica_num = replica_num;

    const int rc = client_->put_from(key, buffer, size, config);
    if (rc != 0) {
        LOG(ERROR) << "PutFrom failed, key=" << key << ", rc=" << rc;
    }
    return rc;
}

int64_t KvStoreClient::GetInto(const std::string& key, void* buffer, std::size_t size) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return -1;
    }

    const int64_t bytes_read = client_->get_into(key, buffer, size);
    if (bytes_read < 0) {
        VLOG(1) << "GetInto failed, key=" << key << ", result=" << bytes_read;
    }
    return bytes_read;
}

std::vector<int> KvStoreClient::BatchPutFrom(const std::vector<std::string>& keys,
                                              const std::vector<void*>& buffers,
                                              const std::vector<std::size_t>& sizes,
                                              std::size_t replica_num) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return std::vector<int>(keys.size(), -1);
    }

    mooncake::ReplicateConfig config;
    config.replica_num = replica_num;

    // Use true batch RPC interface
    return client_->batch_put_from(keys, buffers, sizes, config);
}

std::vector<int64_t> KvStoreClient::BatchGetInto(const std::vector<std::string>& keys,
                                                  const std::vector<void*>& buffers,
                                                  const std::vector<std::size_t>& sizes) {
    if (!client_) {
        LOG(ERROR) << "Client not initialized";
        return std::vector<int64_t>(keys.size(), -1);
    }

    // Use true batch RPC interface
    return client_->batch_get_into(keys, buffers, sizes);
}

}  // namespace mooncake::tools
