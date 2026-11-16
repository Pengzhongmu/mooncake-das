#!/usr/bin/env bash
# Start one Mooncake Store stability role in the foreground.
#
# This is the container-friendly entry point: run one role per container and
# point all roles at the same metadata/master addresses.
#
# Usage:
#   bash run_role.sh metadata
#   bash run_role.sh master
#   bash run_role.sh client
#   bash run_role.sh test
#
# The role can also be supplied through MOONCAKE_ROLE.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)

ROLE=${1:-${MOONCAKE_ROLE:-}}
shift || true

BUILD_DIR=${BUILD_DIR:-"$REPO_ROOT/build-stability"}
RUN_DIR=${RUN_DIR:-"/tmp/mooncake-store-stability"}
LOG_DIR=${LOG_DIR:-"$RUN_DIR/logs"}
ASAN_DIR=${ASAN_DIR:-"$RUN_DIR/asan"}
DETECT_TOOL=${DETECT_TOOL:-none}

MASTER_BIN=${MASTER_BIN:-"$BUILD_DIR/mooncake-store/src/mooncake_master"}
CLIENT_BIN=${CLIENT_BIN:-"$BUILD_DIR/mooncake-store/src/mooncake_client"}
TEST_BIN=${TEST_BIN:-"$BUILD_DIR/mooncake-store/tests/stability/mooncake-test/mooncake_test"}

METADATA_HOST=${METADATA_HOST:-127.0.0.1}
METADATA_PORT=${METADATA_PORT:-8080}
MASTER_PORT=${MASTER_PORT:-50051}
METRICS_PORT=${METRICS_PORT:-19003}
CLIENT_PORT=${CLIENT_PORT:-50052}
TEST_HTTP_PORT=${TEST_HTTP_PORT:-18080}
LOCAL_HOSTNAME=${LOCAL_HOSTNAME:-127.0.0.1}
METADATA_SERVER=${METADATA_SERVER:-"http://${METADATA_HOST}:${METADATA_PORT}/metadata"}
MASTER_SERVER_ADDR=${MASTER_SERVER_ADDR:-"${LOCAL_HOSTNAME}:${MASTER_PORT}"}
PROTOCOL=${PROTOCOL:-tcp}
DEVICE_NAME=${DEVICE_NAME:-}
GLOBAL_SEGMENT_SIZE=${GLOBAL_SEGMENT_SIZE:-256MB}
LOCAL_BUFFER_SIZE=${LOCAL_BUFFER_SIZE:-64MB}
TENANT_ID=${TENANT_ID:-default}
LEASE_TTL_MS=${LEASE_TTL_MS:-500}
CLUSTER_ID=${CLUSTER_ID:-mooncake_stability}
EVICTION_HIGH_WATERMARK=${EVICTION_HIGH_WATERMARK:-0.95}
TEST_HTTP_HOST=${TEST_HTTP_HOST:-0.0.0.0}
TEST_HTTP_THREADS=${TEST_HTTP_THREADS:-8}
TEST_GLOBAL_SEGMENT_SIZE=${TEST_GLOBAL_SEGMENT_SIZE:-0}
TEST_LOCAL_BUFFER_SIZE=${TEST_LOCAL_BUFFER_SIZE:-67108864}
MIN_PUT_SIZE_MB=${MIN_PUT_SIZE_MB:-1}
MAX_PUT_SIZE_MB=${MAX_PUT_SIZE_MB:-16}
ENABLE_ZEROCOPY=${ENABLE_ZEROCOPY:-0}
ZEROCOPY_RECV_POOL_MB=${ZEROCOPY_RECV_POOL_MB:-512}

mkdir -p "$LOG_DIR" "$ASAN_DIR"

log() { echo -e "\033[32m[stability:$ROLE]\033[0m $*"; }
die() { echo -e "\033[31m[stability:$ROLE]\033[0m $*" >&2; exit 1; }

[[ -n "$ROLE" ]] || die "role is required: metadata|master|client|test"

# Build-tree libraries plus optional platform/runtime paths. Missing paths are
# ignored so the same script also works on a plain x86/TCP machine. The metadata
# role is a Python process and must not load the ASan-instrumented build libs.
LDPATH=""
case "$ROLE" in
    master|client|test)
        LDPATH="$BUILD_DIR/mooncake-common:$BUILD_DIR/mooncake-common/etcd:$BUILD_DIR/mooncake-store/src:$BUILD_DIR/mooncake-transfer-engine/src"
        ;;
esac
for extra in ${EXTRA_LD_LIBRARY_PATH:-}; do
    [[ -d "$extra" ]] && LDPATH="${LDPATH:+$LDPATH:}$extra"
done
INHERITED_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
if [[ "$ROLE" == "metadata" ]]; then
    # Do not let the Python metadata server load ASan-instrumented libraries
    # from the build tree inherited from the parent shell.
    FILTERED_LD_LIBRARY_PATH=""
    IFS=':' read -r -a _ld_parts <<<"$INHERITED_LD_LIBRARY_PATH"
    for _part in "${_ld_parts[@]}"; do
        [[ -z "$_part" ]] && continue
        [[ "$_part" == "$BUILD_DIR"* ]] && continue
        FILTERED_LD_LIBRARY_PATH="${FILTERED_LD_LIBRARY_PATH:+$FILTERED_LD_LIBRARY_PATH:}$_part"
    done
    INHERITED_LD_LIBRARY_PATH="$FILTERED_LD_LIBRARY_PATH"
fi
export LD_LIBRARY_PATH="${LDPATH:+$LDPATH:}$INHERITED_LD_LIBRARY_PATH"

# Log path is per-role; ASan appends .<pid>, so restarts do not overwrite.
case "$DETECT_TOOL" in
    asan)
        export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_exe_name=1}:log_path=$ASAN_DIR/asan.$ROLE"
        export LSAN_OPTIONS="${LSAN_OPTIONS:-suppressions=$SCRIPT_DIR/lsan.supp:print_suppressions=0}"
        ;;
    none)
        export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=0}:log_path=$ASAN_DIR/asan.$ROLE"
        export LSAN_OPTIONS="${LSAN_OPTIONS:-}"
        ;;
    *)
        die "DETECT_TOOL must be 'asan' or 'none' (got '$DETECT_TOOL')"
        ;;
esac

extra_args=()
if [[ -n "${ROLE_ARGS:-}" ]]; then
    # ROLE_ARGS is intentionally split so callers can pass gflags/framework
    # arguments without needing a shell array in the environment.
    read -r -a extra_args <<<"${ROLE_ARGS}"
fi

case "$ROLE" in
    metadata)
        METADATA_BIN=${METADATA_BIN:-$(command -v mooncake_http_metadata_server || true)}
        [[ -n "$METADATA_BIN" ]] || die "mooncake_http_metadata_server not found in PATH"
        set -- --host "$METADATA_HOST" --port "$METADATA_PORT"
        log "starting metadata on ${METADATA_HOST}:${METADATA_PORT}"
        exec "$METADATA_BIN" "$@" "${extra_args[@]}"
        ;;
    master)
        [[ -x "$MASTER_BIN" ]] || die "missing $MASTER_BIN; build with -DBUILD_STORE_STABILITY_TESTS=ON first"
        set -- \
            --rpc_port="$MASTER_PORT" \
            --metrics_port="$METRICS_PORT" \
            --default_kv_lease_ttl="$LEASE_TTL_MS" \
            --cluster_id="$CLUSTER_ID" \
            --eviction_high_watermark_ratio="$EVICTION_HIGH_WATERMARK" \
            --enable_http_metadata_server=false \
            --logtostderr=true
        log "starting master rpc=:${MASTER_PORT} cluster=${CLUSTER_ID}"
        exec "$MASTER_BIN" "$@" "${extra_args[@]}"
        ;;
    client)
        [[ -x "$CLIENT_BIN" ]] || die "missing $CLIENT_BIN; build with -DBUILD_STORE_STABILITY_TESTS=ON first"
        set -- \
            --host="$LOCAL_HOSTNAME" \
            --port="$CLIENT_PORT" \
            --metadata_server="$METADATA_SERVER" \
            --master_server_address="$MASTER_SERVER_ADDR" \
            --protocol="$PROTOCOL" \
            --device_names="$DEVICE_NAME" \
            --global_segment_size="$GLOBAL_SEGMENT_SIZE" \
            --local_buffer_size="$LOCAL_BUFFER_SIZE" \
            --tenant_id="$TENANT_ID"
        log "starting client :${CLIENT_PORT} metadata=${METADATA_SERVER} master=${MASTER_SERVER_ADDR}"
        exec "$CLIENT_BIN" "$@" "${extra_args[@]}"
        ;;
    test)
        [[ -x "$TEST_BIN" ]] || die "missing $TEST_BIN; build with -DBUILD_STORE_STABILITY_TESTS=ON first"
        set -- \
            --http-host="$TEST_HTTP_HOST" \
            --http-port="$TEST_HTTP_PORT" \
            --http-threads="$TEST_HTTP_THREADS" \
            --local-hostname="$LOCAL_HOSTNAME" \
            --metadata-server="$METADATA_SERVER" \
            --master-server-addr="$MASTER_SERVER_ADDR" \
            --protocol="$PROTOCOL" \
            --rdma-devices="$DEVICE_NAME" \
            --global-segment-size="$TEST_GLOBAL_SEGMENT_SIZE" \
            --local-buffer-size="$TEST_LOCAL_BUFFER_SIZE" \
            --min-put-size-mb="$MIN_PUT_SIZE_MB" \
            --max-put-size-mb="$MAX_PUT_SIZE_MB"
        if [[ "$ENABLE_ZEROCOPY" == "1" || "$ENABLE_ZEROCOPY" == "true" ]]; then
            set -- "$@" --enable-zerocopy \
                --zerocopy-recv-pool-size-mb="$ZEROCOPY_RECV_POOL_MB"
        fi
        log "starting test HTTP=:${TEST_HTTP_PORT} master=${MASTER_SERVER_ADDR}"
        exec "$TEST_BIN" "$@" "${extra_args[@]}"
        ;;
    *)
        die "unsupported role '$ROLE'; expected metadata|master|client|test"
        ;;
esac
