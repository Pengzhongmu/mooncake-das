# Mooncake Store Stability Tests

This directory contains the Store-specific stability harness. It is deliberately
separate from `mooncake-store/benchmarks/`: benchmarks measure throughput, while
this harness owns ASan/LSan, service lifecycle, fault injection hooks, and result
checks.

For a manual two-node compile/run walkthrough (no Docker/K8s), see
[`TWO_NODE_GUIDE.md`](TWO_NODE_GUIDE.md).

## Layout

| Path | Purpose |
|---|---|
| `CMakeLists.txt` | Adds the C++ HTTP KV tool when `BUILD_STORE_STABILITY_TESTS=ON` |
| `run_stability.sh` | Local all-in-one smoke/bench modes and PID cleanup |
| `run_role.sh` | One-role entry point for multi-container/K8s runs |
| `lsan.supp` | Suppress known third-party process-lifetime leaks |
| `scenarios/*.env` | Optional environment profiles |
| `mooncake-test/` | C++ HTTP KV test tool (`mooncake_test`) |

The Python benchmark remains in `mooncake-store/benchmarks/store_kv_bench.py` and
is used as the load/verification engine by `run_stability.sh bench`.

## Build

Run inside a container that already has the Mooncake dependencies. No Docker
startup is performed by these scripts. Build with the standard CMake flow; the
only new knob is `BUILD_STORE_STABILITY_TESTS`.

### Default stability build (no ASan)

```bash
cmake -S . -B build-stability \
  -DBUILD_STORE_STABILITY_TESTS=ON \
  -DBUILD_UNIT_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_BENCHMARK=OFF \
  -DWITH_STORE_RUST=OFF \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo

cmake --build build-stability \
  --target mooncake_master mooncake_client mooncake_test \
  -j"$(nproc)"
```

### ASan build

```bash
cmake -S . -B build-stability-asan \
  -DBUILD_STORE_STABILITY_TESTS=ON \
  -DENABLE_ASAN=ON \
  -DBUILD_UNIT_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_BENCHMARK=OFF \
  -DWITH_STORE_RUST=OFF \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo

cmake --build build-stability-asan \
  --target mooncake_master mooncake_client mooncake_test \
  -j"$(nproc)"
```

`BUILD_STORE_STABILITY_TESTS` controls whether the stability tooling is built.
`ENABLE_ASAN` is the existing, independent sanitizer switch.

### DCU/SHCA

On a SHCA host, add the SHCA/DTK profile so yalantinglibs does not compile its
stock IBverbs path against the 17-bit SHCA LID types:

```bash
-DUSE_SHCA=ON \
-DUSE_HYGON=ON \
-DYLT_ENABLE_IBV=OFF \
-DDTK_INCLUDE_DIR=/opt/dtk/cuda/cuda-12/targets/x86_64-linux/include \
-DDTK_LIB_DIR=/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib
```

### etcd/HA

```bash
-DUSE_ETCD=ON \
-DSTORE_USE_ETCD=ON
```

### Offline third-party sources

The HTTP KV tool no longer vendors third-party headers. Its CMakeLists uses
`find_package(CLI11)` / `find_package(nlohmann_json)` first and falls back to
`FetchContent` at configure time, pinned to CLI11 `v2.6.1` and nlohmann/json
`v3.12.0`. For offline builds, pass the source directories:

```bash
-DFETCHCONTENT_SOURCE_DIR_CLI11=/path/to/CLI11 \
-DFETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON=/path/to/json
```

## Run

```bash
# HTTP put/get/batch + verify_data smoke
bash mooncake-store/tests/stability/run_stability.sh smoke

# store_kv_bench.py verify_write
bash mooncake-store/tests/stability/run_stability.sh bench

# One role per container; use the same metadata/master addresses everywhere
ROLE=master bash mooncake-store/tests/stability/run_stability.sh role master

# Stop processes started by an earlier run
RUN_DIR=/tmp/mooncake-store-stability-... \
  bash mooncake-store/tests/stability/run_stability.sh stop

# CI uses the same entry point directly:
BUILD_DIR="$PWD/build-stability" \
  bash mooncake-store/tests/stability/run_stability.sh smoke
```

Useful overrides:

| Variable | Default | Meaning |
|---|---|---|
| `BUILD_DIR` | `<repo>/build-stability` | Build tree |
| `RUN_DIR` | `/tmp/mooncake-store-stability-<time>` | Logs, ASan reports, PIDs |
| `DETECT_TOOL` | `none` | `asan` or `none` |
| `PROTOCOL` | `tcp` | `tcp` or `rdma` |
| `DEVICE_NAME` | empty | RDMA device, e.g. `shca_0` |
| `MASTER_PORT` | `50051` | Master RPC port |
| `METRICS_PORT` | `19003` | Master metrics/admin port |
| `CLIENT_PORT` | `50052` | Real client RPC port |
| `TEST_HTTP_PORT` | `18080` | HTTP KV test tool port |
| `METADATA_PORT` | `8080` | HTTP metadata server port |
| `SCENARIO` | empty | Load `scenarios/<name>.env` |
| `BENCH_SCENARIO` | `verify_write` | `store_kv_bench.py` scenario |
| `BENCH_RUNTIME` | `0` | Positive seconds for timed scenarios |
| `ENABLE_ZEROCOPY` | `0` | Set `1` for HTTP tool zero-copy mode |

## ASan behavior

`run_role.sh` sets `ASAN_OPTIONS` with a per-role `log_path`, so multiple
processes and restarts do not overwrite each other. Use `DETECT_TOOL=asan` with
an `ENABLE_ASAN=ON` build to collect reports; `DETECT_TOOL=none` skips the
sanitizer environment for normal or performance runs.

`run_stability.sh` scans `RUN_DIR/asan/asan.*` after a successful run and fails
if it finds `ERROR: AddressSanitizer`, `ERROR: LeakSanitizer`, or a non-zero
`SUMMARY: AddressSanitizer: N byte(s) leaked` line.

## Notes

- `run_stability.sh smoke` starts a separate `mooncake_client` so the test tool
  is a pure consumer, matching the DCU deployment model.
- `run_stability.sh bench` lets `store_kv_bench.py` contribute its own segment;
  no separate client is needed. The script deliberately removes ASan build-tree
  paths from the Python process's `LD_LIBRARY_PATH`; loading an ASan-instrumented
  `libmooncake_store.so` into the interpreter would fail with "ASan runtime does
  not come first".
- The scripts use a Python socket probe instead of `ss`, so they work in slim
  runtime images without `iproute2`.
- `store_kv_bench.py` writes `summary.json` / `journal.jsonl` at the end of a
  phase. For crash/chaos tests, keep the process log as well and inspect
  `summary.json.ok`, not only the exit code.
- For e2e/chaos coverage, reuse `mooncake-store/tests/e2e/`; those binaries are
  built under `BUILD_UNIT_TESTS`, which may conflict with `USE_SHCA=ON`. Use a
  separate non-SHCA profile or a dedicated e2e option if needed.
