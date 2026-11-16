#pragma once

#include <cstddef>
#include <memory>
#include <optional>

#include "client_buffer.h"

namespace mooncake::tools {

/// @brief Zero-copy buffer manager for send and receive operations.
///
/// Send buffer: a single large buffer, read-only, pre-filled with random data.
/// All put_from / batch_put_from requests share it (concurrent reads of
/// immutable memory are safe), which saves memory for performance testing where
/// the exact bytes sent do not matter.
///
/// Receive pool: a single large buffer sub-allocated by mooncake's
/// ClientBufferAllocator (offset allocator), mirroring how the Mooncake client
/// manages its local RDMA staging buffer. Each get_into / batch_get_into
/// allocates a variable-size region on demand and returns it via RAII when the
/// request completes. When the pool is exhausted, allocation fails hard (no
/// fallback), so get_into latency stays purely zero-copy.
class ZeroCopyBufferManager {
   public:
    /// @brief Constructs a ZeroCopyBufferManager.
    /// @param send_buffer_size Size of the single send buffer in bytes.
    /// @param recv_pool_size Size of the receive pool in bytes.
    ZeroCopyBufferManager(std::size_t send_buffer_size,
                          std::size_t recv_pool_size);

    /// @brief Destroys the ZeroCopyBufferManager and frees both buffers.
    ~ZeroCopyBufferManager();

    ZeroCopyBufferManager(const ZeroCopyBufferManager&) = delete;
    ZeroCopyBufferManager& operator=(const ZeroCopyBufferManager&) = delete;
    ZeroCopyBufferManager(ZeroCopyBufferManager&&) = delete;
    ZeroCopyBufferManager& operator=(ZeroCopyBufferManager&&) = delete;

    /// @brief Gets the send buffer pointer for a given size.
    /// @param size Requested data size (must be <= send_buffer_size).
    /// @return Pointer to send buffer, or nullptr if size exceeds buffer size.
    void* GetSendBuffer(std::size_t size);

    /// @brief Gets the send buffer size.
    std::size_t GetSendBufferSize() const { return send_buffer_size_; }

    /// @brief Gets the receive pool base pointer (for RDMA registration).
    void* GetRecvPoolBase() const { return recv_pool_; }

    /// @brief Gets the receive pool size in bytes.
    std::size_t GetRecvPoolSize() const { return recv_pool_size_; }

    /// @brief Allocates a region from the receive pool.
    /// @param size Requested size in bytes.
    /// @return A RAII BufferHandle on success; std::nullopt if the pool has no
    ///         contiguous region large enough (pool exhausted / fragmented).
    std::optional<mooncake::BufferHandle> AllocateRecv(std::size_t size);

   private:
    // Send buffer (single, large, read-only).
    void* send_buffer_;
    std::size_t send_buffer_size_;

    // Receive pool (single, large) sub-allocated by an offset allocator.
    void* recv_pool_;
    std::size_t recv_pool_size_;
    std::shared_ptr<mooncake::ClientBufferAllocator> recv_allocator_;
};

}  // namespace mooncake::tools
