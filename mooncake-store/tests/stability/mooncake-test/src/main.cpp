#include <csignal>

#include <chrono>
#include <cstdint>
#include <string>
#include <thread>

#include <CLI/CLI.hpp>
#include <glog/logging.h>

#include "http_kv_service.hpp"

namespace {

// NOTE: We deliberately do NOT install our own SIGINT/SIGTERM handlers here.
// RealClient's ResourceTracker (initialized inside RealClient::create during
// service.Start) starts a dedicated signal thread that blocks SIGINT/SIGTERM
// process-wide and consumes them via sigwait. On signal it runs tearDownAll()
// (which unregisters local memory and clears segment records from the metadata
// server, cleaning up this node's endpoint), then restores the default handler
// and re-raises the signal to terminate. Installing a std::signal handler here
// races that mechanism: mixing a handler with sigwait leaves the signal neither
// delivered to us nor cleanly processed, so the process hangs and only SIGKILL
// works (which cannot clean up metadata). Letting ResourceTracker own signals
// gives us graceful, metadata-clean shutdown on SIGTERM/SIGINT.

// ASCII art banner for mooncake_test
const char* kBanner = R"(
 _ __ ___   ___   ___  _ __   ___ __ _| | _____      | |_ ___  ___| |_
| '_ ` _ \ / _ \ / _ \| '_ \ / __/ _` | |/ / _ \_____| __/ _ \/ __| __|
| | | | | | (_) | (_) | | | | (_| (_| |   <  __/_____| ||  __/\__ \ |_
|_| |_| |_|\___/ \___/|_| |_|\___\__,_|_|\_\___|      \__\___||___/\__|

)";

std::string GetGitAuthor() {
    // Git author information is embedded at build time via CMake
    return MOONCAKE_TEST_AUTHOR;
}

}  // namespace

int main(int argc, char* argv[]) {
    google::InitGoogleLogging(argv[0]);
    FLAGS_logtostderr = 1;

    // Print banner with author information
    std::cout << kBanner << std::endl;
    std::cout << "Author: " << GetGitAuthor() << std::endl << std::endl;

    std::string http_host = "0.0.0.0";
    std::uint16_t http_port = 18080;
    // Default has NO port on purpose: when --local-hostname carries no ":port",
    // Mooncake auto-binds a free port and retries on metadata conflict, so a
    // restarted test role never collides with a stale endpoint left by a crashed
    // predecessor. Pin a port only for debugging a fixed identity.
    std::string local_hostname = "127.0.0.1";
    std::string metadata_server = "http://localhost:8080/metadata";
    std::uint64_t global_segment_size = 0;
    std::string protocol = "rdma";
    std::string rdma_devices;
    std::string master_server_addr = "localhost:50051";
    std::uint64_t local_buffer_size = 268435456;
    double min_put_size_mb = 1.0;
    double max_put_size_mb = 100.0;
    bool enable_zerocopy = false;
    double zerocopy_recv_pool_size_mb = 512.0;
    std::uint64_t http_threads = std::thread::hardware_concurrency();
    if (http_threads == 0) {
        http_threads = 1;
    }

    CLI::App app{"Mooncake test — HTTP KV API"};
    app.add_option("--http-host", http_host, "HTTP listen host");
    app.add_option("--http-port", http_port,
                   "HTTP listen port for this tool's KV API")
        ->check(CLI::Range(1, 65535));
    app.add_option("--local-hostname", local_hostname,
                   "This node's IP for cluster communication. Prefer an IP with "
                   "NO port (e.g. the node IP): Mooncake then auto-picks a free "
                   "port and retries on metadata conflict, so a restarted test "
                   "role won't collide with a stale endpoint. Add ':port' only to "
                   "pin a fixed identity for debugging.");
    app.add_option("--metadata-server", metadata_server,
                   "Metadata server endpoint (URL or \"P2PHANDSHAKE\")");
    app.add_option("--global-segment-size", global_segment_size,
                   "Segment size (bytes) to contribute to the cluster "
                   "(0 = contribute no storage)");
    app.add_option("--protocol", protocol,
                   "Transport protocol: \"rdma\" or \"tcp\"");
    app.add_option("--rdma-devices", rdma_devices,
                   "RDMA device names, comma-separated (empty = auto-select)");
    app.add_option("--master-server-addr", master_server_addr,
                   "Master service address");
    app.add_option("--local-buffer-size", local_buffer_size,
                   "Local staging buffer size in bytes")
        ->check(CLI::PositiveNumber);
    app.add_option("--min-put-size-mb", min_put_size_mb,
                   "Minimum value size (MB) allowed for put / batch_put")
        ->check(CLI::PositiveNumber);
    app.add_option("--max-put-size-mb", max_put_size_mb,
                   "Maximum value size (MB) allowed for put / batch_put")
        ->check(CLI::PositiveNumber);
    app.add_option("--http-threads", http_threads,
                   "Number of HTTP server worker threads "
                   "(default: hardware concurrency)")
        ->check(CLI::PositiveNumber);

    // Zero-copy options
    app.add_flag("--enable-zerocopy", enable_zerocopy,
                 "Enable zero-copy mode (uses put_from/get_into)");
    app.add_option("--zerocopy-recv-pool-size-mb", zerocopy_recv_pool_size_mb,
                   "Zero-copy receive pool size in MB (single buffer "
                   "sub-allocated per get_into; exhaustion returns HTTP 503)")
        ->check(CLI::PositiveNumber);

    CLI11_PARSE(app, argc, argv);

    if (min_put_size_mb > max_put_size_mb) {
        LOG(ERROR) << "--min-put-size-mb must be less than or equal to "
                      "--max-put-size-mb";
        google::ShutdownGoogleLogging();
        return 1;
    }

    // Reset SIGINT/SIGTERM/SIGHUP disposition to SIG_DFL before starting the
    // service. We do NOT install our own handlers (RealClient's ResourceTracker
    // owns these signals via a sigwait thread once service.Start runs). But the
    // process may be launched with some of these signals set to SIG_IGN inherited
    // from a non-interactive parent -- e.g. `kubectl exec` and shell job control
    // set SIGINT/SIGQUIT to SIG_IGN for background children. A signal left at
    // SIG_IGN is discarded by the kernel and ResourceTracker's sigwait never sees
    // it, so Ctrl-C / SIGINT would be silently ignored and the process could only
    // be killed with SIGKILL. Restoring SIG_DFL here makes ResourceTracker's
    // takeover reliable regardless of how we were started. (SIGTERM was already
    // working because it is not in the inherited ignore set, but we reset it too
    // for symmetry and robustness.)
    for (int sig : {SIGINT, SIGTERM, SIGHUP}) {
        std::signal(sig, SIG_DFL);
    }

    std::string error_message;
    try {
        mooncake::tools::HttpKVService service(
            http_host, http_port, local_hostname, metadata_server,
            static_cast<std::size_t>(global_segment_size),
            static_cast<std::size_t>(local_buffer_size), protocol, rdma_devices,
            master_server_addr, min_put_size_mb, max_put_size_mb,
            enable_zerocopy, zerocopy_recv_pool_size_mb,
            static_cast<std::size_t>(http_threads));

        if (!service.Start(error_message)) {
            LOG(ERROR) << "Failed to start HTTP KV service: " << error_message;
            return 1;
        }

        // Block until a signal arrives. On SIGINT/SIGTERM, ResourceTracker's
        // signal thread runs tearDownAll() (metadata cleanup) and then re-raises
        // the signal to terminate the process, so this loop never returns
        // normally; it just keeps the main thread alive and idle.
        while (true) {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
    } catch (const std::exception& ex) {
        LOG(ERROR) << "Fatal startup error: " << ex.what();
        google::ShutdownGoogleLogging();
        return 1;
    }

    google::ShutdownGoogleLogging();
    return 0;
}
