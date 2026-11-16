#!/usr/bin/env bash
# Local Mooncake Store stability harness.
#
# Modes:
#   smoke    start metadata/master/client/test, run HTTP KV + verify_data checks
#   bench    start metadata/master, run store_kv_bench.py verify_write
#   role     run one role in the foreground (metadata|master|client|test)
#   stop     stop PIDs recorded under RUN_DIR/pids
#
# This script does not start Docker. Run it inside a container that already has
# the build dependencies and the mooncake_store / mooncake_test binaries.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)

MODE=${1:-smoke}
shift || true

BUILD_DIR=${BUILD_DIR:-"$REPO_ROOT/build-stability"}
RUN_DIR=${RUN_DIR:-"/tmp/mooncake-store-stability-$(date +%Y%m%d-%H%M%S)"}
LOG_DIR=${LOG_DIR:-"$RUN_DIR/logs"}
ASAN_DIR=${ASAN_DIR:-"$RUN_DIR/asan"}
PID_DIR=${PID_DIR:-"$RUN_DIR/pids"}
DETECT_TOOL=${DETECT_TOOL:-none}
CHECK_ASAN=${CHECK_ASAN:-1}
SCENARIO=${SCENARIO:-}

if [[ -n "$SCENARIO" ]]; then
    SCENARIO_FILE="$SCRIPT_DIR/scenarios/$SCENARIO.env"
    [[ -f "$SCENARIO_FILE" ]] || { echo "missing scenario file: $SCENARIO_FILE" >&2; exit 2; }
    # shellcheck disable=SC1090
    source "$SCENARIO_FILE"
fi

MASTER_PORT=${MASTER_PORT:-50051}
METRICS_PORT=${METRICS_PORT:-19003}
CLIENT_PORT=${CLIENT_PORT:-50052}
TEST_HTTP_PORT=${TEST_HTTP_PORT:-18080}
METADATA_HOST=${METADATA_HOST:-127.0.0.1}
METADATA_PORT=${METADATA_PORT:-8080}
LOCAL_HOSTNAME=${LOCAL_HOSTNAME:-127.0.0.1}
METADATA_SERVER=${METADATA_SERVER:-"http://${METADATA_HOST}:${METADATA_PORT}/metadata"}
MASTER_SERVER_ADDR=${MASTER_SERVER_ADDR:-"${LOCAL_HOSTNAME}:${MASTER_PORT}"}
PROTOCOL=${PROTOCOL:-tcp}
DEVICE_NAME=${DEVICE_NAME:-}
GLOBAL_SEGMENT_SIZE=${GLOBAL_SEGMENT_SIZE:-256MB}
LOCAL_BUFFER_SIZE=${LOCAL_BUFFER_SIZE:-64MB}
TEST_HTTP_THREADS=${TEST_HTTP_THREADS:-8}
ENABLE_ZEROCOPY=${ENABLE_ZEROCOPY:-0}
BENCH_SCENARIO=${BENCH_SCENARIO:-verify_write}
BENCH_OBJECTS=${BENCH_OBJECTS:-32}
BENCH_VALUE_SIZE=${BENCH_VALUE_SIZE:-4096}
BENCH_RUNTIME=${BENCH_RUNTIME:-0}
BENCH_KEY_PREFIX=${BENCH_KEY_PREFIX:-stab}
BENCH_LOCAL_HOSTNAME=${BENCH_LOCAL_HOSTNAME:-"127.0.0.1:50071"}
BENCH_GLOBAL_SEGMENT_SIZE=${BENCH_GLOBAL_SEGMENT_SIZE:-268435456}
BENCH_LOCAL_BUFFER_SIZE=${BENCH_LOCAL_BUFFER_SIZE:-67108864}
PYTHON_BIN=${PYTHON_BIN:-python3}

DEFAULT_EXTRA_LDPATH=""
for dir in /opt/dtk/lib /opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib /opt/hyhal/lib; do
    [[ -d "$dir" ]] && DEFAULT_EXTRA_LDPATH="$DEFAULT_EXTRA_LDPATH:$dir"
done
EXTRA_LD_LIBRARY_PATH=${EXTRA_LD_LIBRARY_PATH:-${DEFAULT_EXTRA_LDPATH#:}}

export BUILD_DIR RUN_DIR LOG_DIR ASAN_DIR PID_DIR DETECT_TOOL
export MASTER_PORT METRICS_PORT CLIENT_PORT TEST_HTTP_PORT METADATA_HOST METADATA_PORT
export LOCAL_HOSTNAME METADATA_SERVER MASTER_SERVER_ADDR PROTOCOL DEVICE_NAME
export GLOBAL_SEGMENT_SIZE LOCAL_BUFFER_SIZE TEST_HTTP_THREADS ENABLE_ZEROCOPY
export EXTRA_LD_LIBRARY_PATH

mkdir -p "$LOG_DIR" "$ASAN_DIR" "$PID_DIR"

# The Python bench/driver must not load the ASan-instrumented build libraries;
# run_role.sh adds those only for the native master/client/test processes.
export LD_LIBRARY_PATH="${EXTRA_LD_LIBRARY_PATH:+$EXTRA_LD_LIBRARY_PATH:}${LD_LIBRARY_PATH:-}"

PIDS=()
log() { echo -e "\033[32m[stability]\033[0m $*"; }
die() { echo -e "\033[31m[stability]\033[0m $*" >&2; exit 1; }

start_role() {
    local role=$1
    "$SCRIPT_DIR/run_role.sh" "$role" >"$LOG_DIR/$role.log" 2>&1 &
    local pid=$!
    echo "$pid" >"$PID_DIR/$role.pid"
    PIDS+=("$pid")
    log "started $role pid=$pid"
}

stop_pid() {
    local pid=$1
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..200}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

stop_all() {
    local i
    for ((i=${#PIDS[@]}-1; i>=0; i--)); do
        stop_pid "${PIDS[$i]}"
    done
    PIDS=()
}

check_asan() {
    [[ "$DETECT_TOOL" == "asan" ]] || return 0
    local bad=0 file
    shopt -s nullglob
    for file in "$ASAN_DIR"/asan.*; do
        if grep -Eq 'ERROR: (AddressSanitizer|LeakSanitizer)|SUMMARY: AddressSanitizer: [1-9][0-9]* byte' "$file"; then
            echo "ASan/LSan report: $file" >&2
            grep -E 'ERROR: (AddressSanitizer|LeakSanitizer)|SUMMARY: AddressSanitizer: [1-9][0-9]* byte' "$file" | head -20 >&2
            bad=1
        fi
    done
    shopt -u nullglob
    return "$bad"
}

cleanup() {
    local status=$?
    stop_all
    if [[ "$status" -eq 0 && "$CHECK_ASAN" == "1" ]]; then
        check_asan || status=1
    fi
    exit "$status"
}
trap cleanup EXIT

port_open() {
    "$PYTHON_BIN" - "$1" <<'PY'
import socket
import sys

sock = socket.socket()
sock.settimeout(0.3)
try:
    sock.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

wait_port() {
    local name=$1 port=$2 pid=$3
    for _ in {1..150}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "$name exited before listening on :$port" >&2
            tail -n 40 "$LOG_DIR/$name.log" >&2 || true
            return 1
        fi
        if port_open "$port"; then
            return 0
        fi
        sleep 0.2
    done
    echo "$name did not listen on :$port within 30s" >&2
    tail -n 40 "$LOG_DIR/$name.log" >&2 || true
    return 1
}

wait_http() {
    local url=$1 pid=$2
    for _ in {1..150}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "test service exited before becoming ready" >&2
            tail -n 40 "$LOG_DIR/test.log" >&2 || true
            return 1
        fi
        if curl -sf -m 2 "$url/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.2
    done
    echo "test service did not become ready at $url within 30s" >&2
    tail -n 40 "$LOG_DIR/test.log" >&2 || true
    return 1
}

run_http_checks() {
    local url="http://127.0.0.1:$TEST_HTTP_PORT"
    "$PYTHON_BIN" - "$url" <<'PY'
import json
import sys
import urllib.request

base = sys.argv[1].rstrip("/")


def request(path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        base + path,
        data=data,
        headers={"Content-Type": "application/json"},
        method="GET" if payload is None else "POST",
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode())


health = request("/health")
assert health.get("ready") is True, health

for index in range(1, 4):
    key = f"stab_smoke_{index}"
    put = request("/api/kv", {"operator": "put", "key": key, "size": "1.0"})
    assert put.get("code") == 0, put
    got = request("/api/kv", {"operator": "get", "key": key, "verify_data": True})
    assert got.get("code") == 0, got
    assert got.get("data_valid") is True, got
    exist = request("/api/kv", {"operator": "exist", "key": key})
    assert exist.get("exists") is True or exist.get("code") == 1, exist

for index in range(1, 3):
    keys = [f"stab_batch_{index}_{suffix}" for suffix in range(1, 4)]
    put = request(
        "/api/kv",
        {"operator": "batch_put", "key": ",".join(keys), "size": "1.0"},
    )
    assert put.get("success") == len(keys), put
    got = request(
        "/api/kv",
        {"operator": "batch_get", "key": ",".join(keys), "verify_data": True},
    )
    assert got.get("success") == len(keys), got
    for detail in got.get("validation_details") or []:
        assert detail.get("data_valid") is True or detail.get("valid") is True, detail

performance = request("/api/performance")
assert isinstance(performance, (dict, list)), performance
if isinstance(performance, dict):
    performance_keys = sorted(performance)[:8]
else:
    performance_keys = [item.get("tag") for item in performance if isinstance(item, dict)]
print(json.dumps({
    "health_ready": health.get("ready"),
    "performance_tags": performance_keys,
}, sort_keys=True))
PY
}

run_smoke() {
    command -v curl >/dev/null || die "curl is required for smoke checks"
    log "run dir: $RUN_DIR"
    start_role metadata
    wait_port metadata "$METADATA_PORT" "${PIDS[-1]}"
    start_role master
    wait_port master "$MASTER_PORT" "${PIDS[-1]}"
    start_role client
    wait_port client "$CLIENT_PORT" "${PIDS[-1]}"
    start_role test
    wait_http "http://127.0.0.1:$TEST_HTTP_PORT" "${PIDS[-1]}"
    run_http_checks
    log "smoke passed; logs=$LOG_DIR asan=$ASAN_DIR"
}

strip_build_ldpath() {
    local original="${LD_LIBRARY_PATH:-}" result="" part
    local -a parts
    IFS=':' read -r -a parts <<<"$original"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        [[ "$part" == "$BUILD_DIR"* ]] && continue
        result="${result:+$result:}$part"
    done
    printf '%s' "$result"
}

run_bench() {
    log "run dir: $RUN_DIR; scenario=$BENCH_SCENARIO"
    # The Python wheel must not load the ASan-instrumented build libraries.
    local bench_ldpath="${EXTRA_LD_LIBRARY_PATH:+$EXTRA_LD_LIBRARY_PATH:}$(strip_build_ldpath)"
    env LD_LIBRARY_PATH="$bench_ldpath" \
        "$PYTHON_BIN" -c 'import mooncake.store' 2>/dev/null || \
        die "python mooncake.store is not importable; install the wheel or set PYTHONPATH"
    start_role metadata
    wait_port metadata "$METADATA_PORT" "${PIDS[-1]}"
    start_role master
    wait_port master "$MASTER_PORT" "${PIDS[-1]}"

    local -a bench_args=(
        --scenario "$BENCH_SCENARIO"
        --local-hostname "$BENCH_LOCAL_HOSTNAME"
        --metadata-server "$METADATA_SERVER"
        --master-server "$MASTER_SERVER_ADDR"
        --protocol "$PROTOCOL"
        --device-name "$DEVICE_NAME"
        --global-segment-size "$BENCH_GLOBAL_SEGMENT_SIZE"
        --local-buffer-size "$BENCH_LOCAL_BUFFER_SIZE"
        --nr-objects "$BENCH_OBJECTS"
        --value-size "$BENCH_VALUE_SIZE"
        --key-prefix "$BENCH_KEY_PREFIX"
        --pattern "0xA5"
        --verify
        --output-dir "$RUN_DIR/bench"
    )
    if [[ "$BENCH_RUNTIME" -gt 0 ]]; then
        bench_args+=(--runtime "$BENCH_RUNTIME")
    fi

    env LD_LIBRARY_PATH="$bench_ldpath" \
        "$PYTHON_BIN" "$REPO_ROOT/mooncake-store/benchmarks/store_kv_bench.py" \
        "${bench_args[@]}"
    log "bench passed; output=$RUN_DIR/bench"
}

stop_from_pid_dir() {
    local file pid
    shopt -s nullglob
    for file in "$PID_DIR"/*.pid; do
        pid=$(cat "$file" 2>/dev/null || true)
        [[ -n "$pid" ]] && stop_pid "$pid"
        rm -f "$file"
    done
    shopt -u nullglob
    log "stopped processes from $PID_DIR"
}

usage() {
    cat <<EOF
Usage: bash $0 <smoke|bench|role|stop> [role]

  smoke        run metadata + master + client + HTTP KV/verify smoke
  bench        run metadata + master + store_kv_bench.py
  role         run one role in the foreground: metadata|master|client|test
  stop         stop PIDs recorded under $PID_DIR

Environment:
  BUILD_DIR    default: $BUILD_DIR
  RUN_DIR      default: $RUN_DIR
  DETECT_TOOL  asan|none (default: none)
  SCENARIO     optional scenarios/<name>.env file
EOF
}

case "$MODE" in
    smoke)
        run_smoke
        ;;
    bench)
        run_bench
        ;;
    role)
        exec "$SCRIPT_DIR/run_role.sh" "$@"
        ;;
    stop)
        CHECK_ASAN=0
        stop_from_pid_dir
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
