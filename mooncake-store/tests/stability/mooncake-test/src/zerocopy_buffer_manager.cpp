#include "zerocopy_buffer_manager.hpp"

#include <cstdlib>
#include <cstring>
#include <chrono>
#include <random>

#include <glog/logging.h>

namespace mooncake::tools {

namespace {
/// @brief Alignment for RDMA-registered buffers (page size).
constexpr std::size_t kBufferAlignment = 4096;
}  // namespace

ZeroCopyBufferManager::ZeroCopyBufferManager(std::size_t send_buffer_size,
                                             std::size_t recv_pool_size)
    : send_buffer_(nullptr),
      send_buffer_size_(send_buffer_size),
      recv_pool_(nullptr),
      recv_pool_size_(recv_pool_size) {

    // Allocate the single send buffer.
    int rc = posix_memalign(&send_buffer_, kBufferAlignment, send_buffer_size);
    if (rc != 0 || send_buffer_ == nullptr) {
        LOG(FATAL) << "Failed to allocate send buffer: size=" << send_buffer_size
                   << ", error=" << strerror(rc);
    }

    // Pre-fill send buffer with random data once. Requests only take read-only
    // prefixes of it afterwards.
    std::mt19937_64 gen(
        std::chrono::steady_clock::now().time_since_epoch().count());
    std::uniform_int_distribution<> dist(0, 255);
    char* buf = static_cast<char*>(send_buffer_);
    for (std::size_t i = 0; i < send_buffer_size; ++i) {
        buf[i] = static_cast<char>(dist(gen));
    }
    LOG(INFO) << "Zero-copy send buffer allocated: "
              << (send_buffer_size / 1024 / 1024)
              << " MB, pre-filled with random data";

    // Allocate the single receive pool and wrap it with the offset allocator.
    rc = posix_memalign(&recv_pool_, kBufferAlignment, recv_pool_size);
    if (rc != 0 || recv_pool_ == nullptr) {
        LOG(FATAL) << "Failed to allocate recv pool: size=" << recv_pool_size
                   << ", error=" << strerror(rc);
    }

    // External-memory allocator: it does NOT register RDMA and does NOT free the
    // memory on destruction. We own registration (via IPC) and free() ourselves.
    recv_allocator_ = mooncake::ClientBufferAllocator::create(
        recv_pool_, recv_pool_size);
    if (!recv_allocator_) {
        LOG(FATAL) << "Failed to create recv pool allocator";
    }
    LOG(INFO) << "Zero-copy recv pool allocated: "
              << (recv_pool_size / 1024 / 1024)
              << " MB, managed by offset allocator";
}

ZeroCopyBufferManager::~ZeroCopyBufferManager() {
    // Release the allocator first (does not touch external memory), then free
    // the underlying pool. RDMA unregistration is performed by the service
    // before this destructor runs.
    recv_allocator_.reset();

    if (recv_pool_) {
        std::free(recv_pool_);
        recv_pool_ = nullptr;
    }
    if (send_buffer_) {
        std::free(send_buffer_);
        send_buffer_ = nullptr;
    }
    LOG(INFO) << "Zero-copy buffers destroyed";
}

void* ZeroCopyBufferManager::GetSendBuffer(std::size_t size) {
    if (size > send_buffer_size_) {
        LOG(ERROR) << "Requested send size " << size
                   << " exceeds send buffer size " << send_buffer_size_;
        return nullptr;
    }

    // Always return the beginning of the single send buffer. This is
    // intentional and thread-safe under concurrent access because:
    //   1. The buffer is filled once at construction and never mutated again.
    //   2. put_from / batch_put_from only READ from it (RDMA reads the source).
    //   3. Concurrent reads of immutable memory need no synchronization.
    // For performance testing we do not care about the exact bytes sent, so a
    // single shared read-only buffer saves memory versus one buffer per thread.
    return send_buffer_;
}

std::optional<mooncake::BufferHandle> ZeroCopyBufferManager::AllocateRecv(
    std::size_t size) {
    // Thread-safe: OffsetAllocator guards allocation with its own mutex.
    // Returns std::nullopt when the pool has no contiguous region large enough.
    return recv_allocator_->allocate(size);
}

}  // namespace mooncake::tools
