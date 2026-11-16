#pragma once

#include <cstddef>
#include <memory>
#include <string>
#include <span>
#include <vector>

#include "real_client.h"

namespace mooncake::tools {

/// @brief KVStore client wrapper for performance testing.
/// @note Wraps a mooncake::RealClient that connects directly to the cluster.
class KvStoreClient {
   public:
    /// @brief Constructs a new KvStoreClient.
    KvStoreClient();

    /// @brief Destroys the KvStoreClient.
    ~KvStoreClient();

    KvStoreClient(const KvStoreClient&) = delete;
    KvStoreClient& operator=(const KvStoreClient&) = delete;
    KvStoreClient(KvStoreClient&&) = delete;
    KvStoreClient& operator=(KvStoreClient&&) = delete;

    /// @brief Sets up the client connection to the cluster.
    /// @param local_hostname This node's address for cluster communication.
    /// @param metadata_server Metadata server endpoint (URL or "P2PHANDSHAKE").
    /// @param global_segment_size Segment size (bytes) to contribute to the
    ///        cluster; 0 means this node contributes no storage.
    /// @param local_buffer_size Local staging buffer size in bytes.
    /// @param protocol Transport protocol ("rdma" or "tcp").
    /// @param rdma_devices RDMA device names (empty = auto-select).
    /// @param master_server_addr Master service address.
    /// @return 0 on success, non-zero on failure.
    int Setup(const std::string& local_hostname,
              const std::string& metadata_server,
              std::size_t global_segment_size, std::size_t local_buffer_size,
              const std::string& protocol, const std::string& rdma_devices,
              const std::string& master_server_addr);

    /// @brief Stores a value with the specified key.
    /// @param key The key to store.
    /// @param value The value to store.
    /// @param replica_num Number of replicas (default: 1).
    /// @return 0 on success, non-zero on failure.
    int Put(const std::string& key, const std::string& value,
            std::size_t replica_num = 1);

    /// @brief Stores a value with the specified key (zero-copy input).
    /// @param key The key to store.
    /// @param value Read-only value bytes.
    /// @param replica_num Number of replicas (default: 1).
    /// @return 0 on success, non-zero on failure.
    int Put(const std::string& key, std::span<const char> value,
            std::size_t replica_num = 1);

    /// @brief Retrieves a value by key.
    /// @param key The key to retrieve.
    /// @param value Output parameter for the retrieved value.
    /// @return 0 on success, non-zero on failure.
    int Get(const std::string& key, std::string& value);

    /// @brief Checks if a key exists.
    /// @param key The key to check.
    /// @return 1 if exists, 0 if not exists, -1 on error.
    int Exist(const std::string& key);

    /// @brief Stores multiple key-value pairs.
    /// @param keys The keys to store.
    /// @param values The values to store.
    /// @param replica_num Number of replicas (default: 1).
    /// @return Vector of result codes for each put operation.
    std::vector<int> BatchPut(const std::vector<std::string>& keys,
                              const std::vector<std::string>& values,
                              std::size_t replica_num = 1);

    /// @brief Stores multiple keys with the same value (zero-copy input).
    /// @param keys The keys to store.
    /// @param value Read-only value bytes for all keys.
    /// @param replica_num Number of replicas (default: 1).
    /// @return Vector of result codes for each put operation.
    std::vector<int> BatchPut(const std::vector<std::string>& keys,
                                std::span<const char> value,
                                std::size_t replica_num = 1);

    /// @brief Retrieves multiple values by keys.
    /// @param keys The keys to retrieve.
    /// @param values Output vector for the retrieved values.
    /// @return Vector of results: 0 on success, -1 on failure.
    std::vector<int> BatchGet(const std::vector<std::string>& keys,
                              std::vector<std::string>& values);

    /// @brief Checks if multiple keys exist.
    /// @param keys The keys to check.
    /// @return Vector of results: 1 if exists, 0 if not exists, -1 on error.
    std::vector<int> BatchExist(const std::vector<std::string>& keys);

    /// @brief Removes a key.
    /// @param key The key to remove.
    /// @return 0 on success, non-zero on failure.
    int Remove(const std::string& key);

    /// @brief Removes all keys matching the regex pattern.
    /// @param regex The regex pattern.
    /// @param force Force removal.
    /// @return Number of removed keys, or -1 on error.
    long RemoveByRegex(const std::string& regex, bool force);

    /// @brief Removes all keys.
    /// @param force Force removal.
    /// @return Number of removed keys, or -1 on error.
    long RemoveAll(bool force);

    /// @brief Performs a health check.
    /// @return Health status code.
    int HealthCheck();

    // Zero-copy interfaces

    /// @brief Registers a memory buffer for zero-copy operations.
    /// @param buffer The buffer pointer.
    /// @param size The buffer size in bytes.
    /// @return 0 on success, non-zero on failure.
    int RegisterBuffer(void* buffer, std::size_t size);

    /// @brief Unregisters a memory buffer.
    /// @param buffer The buffer pointer.
    /// @return 0 on success, non-zero on failure.
    int UnregisterBuffer(void* buffer);

    /// @brief Stores a value from a registered buffer (zero-copy write).
    /// @param key The key to store.
    /// @param buffer The registered buffer pointer.
    /// @param size The size of data to write.
    /// @param replica_num Number of replicas (default: 1).
    /// @return 0 on success, non-zero on failure.
    int PutFrom(const std::string& key, void* buffer, std::size_t size,
                std::size_t replica_num = 1);

    /// @brief Retrieves a value into a registered buffer (zero-copy read).
    /// @param key The key to retrieve.
    /// @param buffer The registered buffer pointer.
    /// @param size The buffer size.
    /// @return Number of bytes read on success, -1 on failure.
    int64_t GetInto(const std::string& key, void* buffer, std::size_t size);

    /// @brief Stores multiple key-value pairs from registered buffers (zero-copy write).
    /// @param keys The keys to store.
    /// @param buffers The registered buffer pointers.
    /// @param sizes The sizes of data to write for each key.
    /// @param replica_num Number of replicas (default: 1).
    /// @return Vector of result codes for each put operation.
    std::vector<int> BatchPutFrom(const std::vector<std::string>& keys,
                                  const std::vector<void*>& buffers,
                                  const std::vector<std::size_t>& sizes,
                                  std::size_t replica_num = 1);

    /// @brief Retrieves multiple values into registered buffers (zero-copy read).
    /// @param keys The keys to retrieve.
    /// @param buffers The registered buffer pointers.
    /// @param sizes The buffer sizes.
    /// @return Vector of bytes read for each key (or -1 on failure).
    std::vector<int64_t> BatchGetInto(const std::vector<std::string>& keys,
                                      const std::vector<void*>& buffers,
                                      const std::vector<std::size_t>& sizes);

   private:
    std::shared_ptr<mooncake::RealClient> client_;
};

}  // namespace mooncake::tools
