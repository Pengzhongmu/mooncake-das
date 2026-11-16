#!/usr/bin/env bash
# Copyright (c) 2026 Hygon Information Technology Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# One-click start/stop of Mooncake Store master/client processes across nodes.
#
# Topology lives in a simple config file; see store_cluster.conf.example.
# A role entry is:
#
#   <master|client> <host|local> <port> [extra gflags...]
#
# Examples:
#   bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf start
#   bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf status
#   bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf stop
#
# The script starts master entries first, waits for their ports, then starts
# client entries. "stop" walks the list in reverse order. Remote nodes are
# reached over SSH; "local", "localhost", and "127.0.0.1" run in place.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_CONFIG="$SCRIPT_DIR/store_cluster.conf"

CONFIG_FILE="$DEFAULT_CONFIG"
ACTION=""
DRY_RUN=0

RUN_DIR="/tmp/mooncake-store-cluster"
MASTER_BIN="mooncake_master"
CLIENT_BIN="mooncake_test"
CONTAINER=""
KILL_EXISTING=1
SSH_USER=""
SSH_PORT="22"
SSH_KEY=""
SSH_OPTIONS=""
PROTOCOL="tcp"
DEVICE_NAMES=""
GLOBAL_SEGMENT_SIZE="4GB"
LOCAL_BUFFER_SIZE="256MB"
GLOBAL_SEGMENT_SIZE_BYTES=""
LOCAL_BUFFER_SIZE_BYTES=""
DEFAULT_LOCAL_BUFFER_SIZE_BYTES=268435456
HTTP_HOST="0.0.0.0"
HTTP_THREADS=8
MIN_PUT_SIZE_MB="1.0"
MAX_PUT_SIZE_MB="16.0"
ENABLE_ZEROCOPY=0
ZEROCOPY_RECV_POOL_MB="512.0"
UNSET_PROXY=0
CLIENT_HEALTH_CHECK=1
LOCK_FILE="/tmp/mooncake-store-cluster.lock"
LOCK_TIMEOUT=30
MASTER_SERVER_ADDRESS=""
METADATA_SERVER=""
ENV_FILE="/opt/dtk/env.sh"
LD_LIBRARY_PATH_EXTRA=""
TE_FILTERS=""
TE_FILTERS_EXCLUDE=""
START_TIMEOUT=30
STOP_TIMEOUT=15
ALLOW_MULTIPLE_MASTERS=0

ENTRY_ROLE=()
ENTRY_HOST=()
ENTRY_IP=()
ENTRY_CONTAINER=()
ENTRY_PORT=()
ENTRY_SEGMENT_SIZE=()
ENTRY_LOCAL_BUFFER_SIZE=()
ENTRY_EXTRA=()
ROLE_ARGS=()
SSH_CMD=()
RUNTIME_PREFIX=""
STARTED=0
STARTED_ENTRIES=()
ENTRY_STARTED=0
declare -A HOST_IP=()
declare -A HOST_CONTAINER=()
declare -A HOST_MAPPED=()

usage() {
    cat <<'EOF'
Usage: bash scripts/hygon/start_store_cluster.sh [options] <start|stop|restart|status|check>

Options:
  -c, --config PATH   Topology config file (default: store_cluster.conf
                      next to this script)
  -n, --dry-run       Print remote commands instead of executing them
  -h, --help          Show this help

Config format:
  Global key=value lines (run_dir, master_bin, client_bin, container,
  kill_existing, ssh_user, ssh_port, ssh_key, ssh_options, protocol,
  device_names,
  global_segment_size, local_buffer_size, http_host, http_threads,
  min_put_size_mb, max_put_size_mb, enable_zerocopy,
  zerocopy_recv_pool_mb, unset_proxy, client_health_check,
  lock_file, lock_timeout, env_file, ld_library_path, te_filters,
  te_filters_exclude, master_server_address, metadata_server,
  start_timeout, stop_timeout, allow_multiple_masters).

  Host mapping (optional, recommended when hostname != node IP or when
  each node uses a different Docker container name):
    host <hostname> <node_ip> <container|->

  Role lines:
    <master> <hostname|local> <port> [extra gflags...]
    <client> <hostname|local> <http_port> [segment_size] [local_buffer_size] [extra gflags...]

  "master" starts mooncake_master; "client" starts mooncake_test (the HTTP KV
  test tool). segment_size/local_buffer_size accept bytes or a K/M/G/T suffix.
  Defaults are 4GB and 256MB respectively; omitted values use the global
  global_segment_size / local_buffer_size settings. Repeat a client line with
  different HTTP ports to run multiple mooncake_test instances on one node;
  the <http_port> column is the test tool's HTTP port.
  master_server_address and metadata_server are derived from the master
  entry when they are not set explicitly.

Examples:
  cp scripts/hygon/store_cluster.conf.example scripts/hygon/store_cluster.conf
  # edit the addresses, then:
  bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf check
  bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf start
  bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf status
  bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf stop
EOF
}

log() { printf '[cluster] %s\n' "$*"; }
warn() { printf '[cluster] WARN: %s\n' "$*" >&2; }
die() { printf '[cluster] ERROR: %s\n' "$*" >&2; exit 1; }

is_local() {
    case "$1" in
        local|localhost|127.0.0.1) return 0 ;;
        *) return 1 ;;
    esac
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

ssh_target() {
    if [[ -n "$SSH_USER" ]]; then
        printf '%s@%s' "$SSH_USER" "$1"
    else
        printf '%s' "$1"
    fi
}

run_on_host() {
    local host=$1
    local cmd=$2
    local detached=${3:-0}
    local container=${4-$CONTAINER}
    local target_cmd=$cmd

    if [[ -n "$container" ]]; then
        if ((detached)); then
            target_cmd="docker exec -d $(printf '%q' "$container") bash -lc $(printf '%q' "$cmd")"
        else
            target_cmd="docker exec $(printf '%q' "$container") bash -lc $(printf '%q' "$cmd")"
        fi
    fi

    if ((DRY_RUN)); then
        printf '[dry-run] %s: %s\n' "$host" "$target_cmd"
        return 0
    fi

    if is_local "$host"; then
        bash -lc "$target_cmd"
    else
        "${SSH_CMD[@]}" "$(ssh_target "$host")" "bash -lc $(printf '%q' "$target_cmd")"
    fi
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            -c|--config)
                (($# >= 2)) || die "$1 requires a path"
                CONFIG_FILE=$2
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            start|stop|restart|status|check)
                ACTION=$1
                shift
                ;;
            *)
                die "unknown argument: $1 (use --help)"
                ;;
        esac
    done
    [[ -n "$ACTION" ]] || { usage >&2; exit 2; }
}

parse_config() {
    [[ -f "$CONFIG_FILE" ]] ||
        die "config not found: $CONFIG_FILE (copy store_cluster.conf.example to store_cluster.conf)"

    local line role host port fourth fifth rest segment_size local_buffer_size extra key value
    local kind ssh_alias ip container_idx
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == \#* ]] && continue
        line="${line%%[[:space:]]#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Global setting: "<identifier>=<value>". A role line starts with
        # "master"/"client", so its first token is not a bare identifier.
        if [[ "$line" == *=* ]]; then
            key=${line%%=*}
            if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                value=${line#*=}
                case "$key" in
                    run_dir) RUN_DIR=$value ;;
                    master_bin) MASTER_BIN=$value ;;
                    client_bin) CLIENT_BIN=$value ;;
                    container) CONTAINER=$value ;;
                    kill_existing) KILL_EXISTING=$value ;;
                    ssh_user) SSH_USER=$value ;;
                    ssh_port) SSH_PORT=$value ;;
                    ssh_key) SSH_KEY=$value ;;
                    ssh_options) SSH_OPTIONS=$value ;;
                    protocol) PROTOCOL=$value ;;
                    device_names) DEVICE_NAMES=$value ;;
                    global_segment_size) GLOBAL_SEGMENT_SIZE=$value ;;
                    local_buffer_size) LOCAL_BUFFER_SIZE=$value ;;
                    http_host) HTTP_HOST=$value ;;
                    http_threads) HTTP_THREADS=$value ;;
                    min_put_size_mb) MIN_PUT_SIZE_MB=$value ;;
                    max_put_size_mb) MAX_PUT_SIZE_MB=$value ;;
                    enable_zerocopy) ENABLE_ZEROCOPY=$value ;;
                    zerocopy_recv_pool_mb) ZEROCOPY_RECV_POOL_MB=$value ;;
                    unset_proxy) UNSET_PROXY=$value ;;
                    client_health_check) CLIENT_HEALTH_CHECK=$value ;;
                    lock_file) LOCK_FILE=$value ;;
                    lock_timeout) LOCK_TIMEOUT=$value ;;
                    master_server_address) MASTER_SERVER_ADDRESS=$value ;;
                    metadata_server) METADATA_SERVER=$value ;;
                    env_file) ENV_FILE=$value ;;
                    ld_library_path) LD_LIBRARY_PATH_EXTRA=$value ;;
                    te_filters) TE_FILTERS=$value ;;
                    te_filters_exclude) TE_FILTERS_EXCLUDE=$value ;;
                    start_timeout) START_TIMEOUT=$value ;;
                    stop_timeout) STOP_TIMEOUT=$value ;;
                    allow_multiple_masters) ALLOW_MULTIPLE_MASTERS=$value ;;
                    *) die "unknown config key '$key' in $CONFIG_FILE" ;;
                esac
                continue
            fi
        fi

        if [[ "$line" == host[[:space:]]* ]]; then
            read -r kind ssh_alias ip container_idx <<<"$line"
            [[ "$kind" == "host" && -n "$ssh_alias" && -n "$ip" && -n "$container_idx" ]] ||
                die "invalid host mapping (expected: host <hostname> <ip> <container|->): $line"
            if [[ "$container_idx" == "-" ]]; then
                container_idx=""
            elif [[ -n "$container_idx" ]]; then
                [[ "$container_idx" =~ ^[A-Za-z0-9_.-]+$ ]] ||
                    die "invalid container name for $ssh_alias: $container_idx"
            fi
            HOST_IP[$ssh_alias]=$ip
            HOST_CONTAINER[$ssh_alias]=$container_idx
            HOST_MAPPED[$ssh_alias]=1
            continue
        fi

        read -r role host port fourth fifth rest <<<"$line"
        [[ -n "$role" && -n "$host" && -n "$port" ]] ||
            die "invalid role line (expected: <master|client> <hostname|local> <port> [segment_size] [local_buffer_size]): $line"
        case "$role" in
            master|client) ;;
            *) die "unknown role '$role' in $CONFIG_FILE" ;;
        esac
        [[ "$port" =~ ^[0-9]+$ ]] || die "invalid port '$port' in $CONFIG_FILE"
        ((port >= 1 && port <= 65535)) || die "port out of range: $port"

        segment_size=""
        local_buffer_size=""
        local -a extra_parts=()
        if [[ "$role" == "client" && -n "$fourth" && "$fourth" != -* ]]; then
            segment_size=$(size_to_bytes "$fourth") ||
                die "invalid segment_size '$fourth' for client $host:$port"
            if [[ -n "$fifth" && "$fifth" != -* ]]; then
                local_buffer_size=$(size_to_bytes "$fifth") ||
                    die "invalid local_buffer_size '$fifth' for client $host:$port"
                [[ -n "$rest" ]] && extra_parts+=("$rest")
            else
                [[ -n "$fifth" ]] && extra_parts+=("$fifth")
                [[ -n "$rest" ]] && extra_parts+=("$rest")
            fi
        else
            [[ -n "$fourth" ]] && extra_parts+=("$fourth")
            [[ -n "$fifth" ]] && extra_parts+=("$fifth")
            [[ -n "$rest" ]] && extra_parts+=("$rest")
        fi
        extra="${extra_parts[*]}"

        ENTRY_ROLE+=("$role")
        ENTRY_HOST+=("$host")
        ENTRY_PORT+=("$port")
        ENTRY_SEGMENT_SIZE+=("$segment_size")
        ENTRY_LOCAL_BUFFER_SIZE+=("$local_buffer_size")
        ENTRY_EXTRA+=("$extra")
    done <"$CONFIG_FILE"

    ((${#ENTRY_ROLE[@]} > 0)) || die "no role entries in $CONFIG_FILE"

    ENTRY_IP=()
    ENTRY_CONTAINER=()
    local i ssh_host mapped_ip mapped_container
    for i in "${!ENTRY_ROLE[@]}"; do
        ssh_host=${ENTRY_HOST[$i]}
        if [[ -n "${HOST_MAPPED[$ssh_host]:-}" ]]; then
            mapped_ip=${HOST_IP[$ssh_host]}
            mapped_container=${HOST_CONTAINER[$ssh_host]:-}
        else
            if is_local "$ssh_host"; then
                mapped_ip="127.0.0.1"
                mapped_container=""
            else
                mapped_ip=$ssh_host
                mapped_container=$CONTAINER
            fi
        fi
        ENTRY_IP+=("$mapped_ip")
        ENTRY_CONTAINER+=("$mapped_container")
    done
}

size_to_bytes() {
    local value=$1
    local number unit multiplier

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
        return 0
    fi
    if [[ "$value" =~ ^([0-9]+)([KkMmGgTt])[Bb]?$ ]]; then
        number=${BASH_REMATCH[1]}
        unit=${BASH_REMATCH[2]^^}
        case "$unit" in
            K) multiplier=1024 ;;
            M) multiplier=1048576 ;;
            G) multiplier=1073741824 ;;
            T) multiplier=1099511627776 ;;
        esac
        printf '%s' "$((number * multiplier))"
        return 0
    fi
    return 1
}

format_size() {
    local bytes=${1:-0}
    awk -v b="$bytes" 'BEGIN {
        if (b >= 1073741824) {
            value = b / 1073741824
            unit = "GB"
        } else {
            value = b / 1048576
            unit = "MB"
        }
        text = sprintf("%.1f", value)
        sub(/\.0$/, "", text)
        printf "%s%s", text, unit
    }'
}

effective_local_buffer_size() {
    local value=${1:-}
    if [[ -z "$value" || "$value" == "0" ]]; then
        value=$LOCAL_BUFFER_SIZE_BYTES
    fi
    if [[ -z "$value" || "$value" == "0" ]]; then
        value=$DEFAULT_LOCAL_BUFFER_SIZE_BYTES
    fi
    printf '%s' "$value"
}

validate_config() {
    [[ "$RUN_DIR" == /* ]] || die "run_dir must be an absolute path: $RUN_DIR"
    [[ "$START_TIMEOUT" =~ ^[0-9]+$ ]] || die "start_timeout must be an integer"
    ((START_TIMEOUT > 0)) || die "start_timeout must be greater than 0"
    [[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]] || die "stop_timeout must be an integer"
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "ssh_port must be an integer"
    ((SSH_PORT >= 1 && SSH_PORT <= 65535)) || die "ssh_port out of range: $SSH_PORT"
    [[ "$ALLOW_MULTIPLE_MASTERS" == 0 || "$ALLOW_MULTIPLE_MASTERS" == 1 ]] ||
        die "allow_multiple_masters must be 0 or 1"
    [[ -n "$MASTER_BIN" ]] || die "master_bin is empty"
    [[ -n "$CLIENT_BIN" ]] || die "client_bin is empty"
    if [[ -n "$CONTAINER" ]]; then
        [[ "$CONTAINER" =~ ^[A-Za-z0-9_.-]+$ ]] ||
            die "container must be a Docker container name: $CONTAINER"
    fi
    [[ "$KILL_EXISTING" == 0 || "$KILL_EXISTING" == 1 ]] ||
        die "kill_existing must be 0 or 1"
    [[ -n "$HTTP_HOST" ]] || die "http_host is empty"
    [[ "$HTTP_THREADS" =~ ^[1-9][0-9]*$ ]] ||
        die "http_threads must be a positive integer"

    GLOBAL_SEGMENT_SIZE_BYTES=$(size_to_bytes "$GLOBAL_SEGMENT_SIZE") ||
        die "invalid global_segment_size: $GLOBAL_SEGMENT_SIZE (use bytes or e.g. 256MB)"
    LOCAL_BUFFER_SIZE_BYTES=$(size_to_bytes "$LOCAL_BUFFER_SIZE") ||
        die "invalid local_buffer_size: $LOCAL_BUFFER_SIZE (use bytes or e.g. 64MB)"

    awk -v min="$MIN_PUT_SIZE_MB" -v max="$MAX_PUT_SIZE_MB" \
        'BEGIN { exit !(min + 0 > 0 && max + 0 > 0 && min + 0 <= max + 0) }' ||
        die "min_put_size_mb/max_put_size_mb must be positive and min <= max"
    awk -v value="$ZEROCOPY_RECV_POOL_MB" \
        'BEGIN { exit !(value + 0 > 0) }' ||
        die "zerocopy_recv_pool_mb must be positive"

    case "$ENABLE_ZEROCOPY" in
        1|true|TRUE|yes|YES) ENABLE_ZEROCOPY=1 ;;
        0|false|FALSE|no|NO) ENABLE_ZEROCOPY=0 ;;
        *) die "enable_zerocopy must be 0/1 or true/false" ;;
    esac
    [[ "$UNSET_PROXY" == 0 || "$UNSET_PROXY" == 1 ]] ||
        die "unset_proxy must be 0 or 1"
    [[ "$CLIENT_HEALTH_CHECK" == 0 || "$CLIENT_HEALTH_CHECK" == 1 ]] ||
        die "client_health_check must be 0 or 1"
    [[ "$LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || die "lock_timeout must be an integer"
    if [[ -n "$LOCK_FILE" ]]; then
        [[ "$LOCK_FILE" == /* ]] || die "lock_file must be an absolute path: $LOCK_FILE"
    fi

    local i key master_count=0 master_host="" master_ip="" master_port="" master_extra=""
    local -A seen=()
    for i in "${!ENTRY_ROLE[@]}"; do
        key="${ENTRY_IP[$i]}:${ENTRY_PORT[$i]}"
        [[ -z "${seen[$key]:-}" ]] || die "duplicate IP/port: $key"
        seen[$key]=1
        if [[ "${ENTRY_ROLE[$i]}" == "master" ]]; then
            master_count=$((master_count + 1))
            if ((master_count == 1)); then
                master_host=${ENTRY_HOST[$i]}
                master_ip=${ENTRY_IP[$i]}
                master_port=${ENTRY_PORT[$i]}
                master_extra=${ENTRY_EXTRA[$i]}
            fi
        fi
    done

    if ((master_count > 1 && ALLOW_MULTIPLE_MASTERS != 1)); then
        die "more than one master entry; set allow_multiple_masters=1 only for an HA setup"
    fi

    if ((master_count > 0)); then
        if [[ -z "$MASTER_SERVER_ADDRESS" ]]; then
            MASTER_SERVER_ADDRESS="${master_ip}:${master_port}"
        fi
        if [[ -z "$METADATA_SERVER" ]]; then
            local metadata_port=8080 metadata_enabled=0
            if [[ "$master_extra" =~ --enable_http_metadata_server[=\ ]false ]]; then
                metadata_enabled=0
            elif [[ "$master_extra" =~ (^|[[:space:]])--enable_http_metadata_server($|[[:space:]]|=true) ]]; then
                metadata_enabled=1
            fi
            if ((!metadata_enabled)); then
                die "master does not enable the HTTP metadata server; set metadata_server=... or add --enable_http_metadata_server=true"
            fi
            if [[ "$master_extra" =~ --http_metadata_server_port[=\ ]([0-9]+) ]]; then
                metadata_port=${BASH_REMATCH[1]}
            fi
            METADATA_SERVER="http://${master_ip}:${metadata_port}/metadata"
        fi
    else
        [[ -n "$MASTER_SERVER_ADDRESS" ]] ||
            die "no master entry and master_server_address is empty"
        [[ -n "$METADATA_SERVER" ]] ||
            die "no master entry and metadata_server is empty"
    fi
}

build_ssh_cmd() {
    SSH_CMD=(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10
        -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
    if [[ -n "$SSH_KEY" ]]; then
        SSH_CMD+=(-i "$SSH_KEY")
    fi
    if [[ -n "$SSH_OPTIONS" ]]; then
        local -a opts=()
        read -r -a opts <<<"$SSH_OPTIONS"
        SSH_CMD+=("${opts[@]}")
    fi
}

build_runtime_prefix() {
    RUNTIME_PREFIX=""
    if [[ -n "$ENV_FILE" ]]; then
        RUNTIME_PREFIX+="if [ -f $(printf '%q' "$ENV_FILE") ]; then . $(printf '%q' "$ENV_FILE") >/dev/null 2>&1; fi; "
    fi
    if ((UNSET_PROXY)); then
        RUNTIME_PREFIX+="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy; "
    fi
    if [[ -n "$TE_FILTERS" ]]; then
        RUNTIME_PREFIX+="MC_TE_FILTERS=$(printf '%q' "$TE_FILTERS"); export MC_TE_FILTERS; "
    fi
    if [[ -n "$TE_FILTERS_EXCLUDE" ]]; then
        RUNTIME_PREFIX+="MC_TE_FILTERS_EXCLUDE=$(printf '%q' "$TE_FILTERS_EXCLUDE"); export MC_TE_FILTERS_EXCLUDE; "
    fi
    if [[ -n "$LD_LIBRARY_PATH_EXTRA" ]]; then
        RUNTIME_PREFIX+="LD_LIBRARY_PATH=$(printf '%q' "$LD_LIBRARY_PATH_EXTRA")\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}; export LD_LIBRARY_PATH; "
    fi
}

check_local_tools() {
    local cmd host has_remote=0 need_local_docker=0 i

    for cmd in awk; do
        command -v "$cmd" >/dev/null 2>&1 || die "required command is missing on the control node: $cmd"
    done
    if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
        die "ssh_key does not exist on the control node: $SSH_KEY"
    fi
    if [[ -n "$LOCK_FILE" ]]; then
        case "$ACTION" in
            start|stop|restart)
                command -v flock >/dev/null 2>&1 ||
                    die "flock is required for lock_file; install util-linux or set lock_file="
                ;;
        esac
    fi
    for i in "${!ENTRY_ROLE[@]}"; do
        if is_local "${ENTRY_HOST[$i]}" && [[ -n "${ENTRY_CONTAINER[$i]}" ]]; then
            need_local_docker=1
            break
        fi
    done
    if ((need_local_docker)); then
        command -v docker >/dev/null 2>&1 ||
            die "docker is required on the control node for a local container mapping"
    fi
    for host in "${ENTRY_HOST[@]}"; do
        if ! is_local "$host"; then
            has_remote=1
            break
        fi
    done
    if ((has_remote)); then
        command -v ssh >/dev/null 2>&1 || die "ssh is required for remote hosts"
    fi
}

acquire_lock() {
    [[ -n "$LOCK_FILE" ]] || return 0
    exec 9>"$LOCK_FILE" || die "cannot open lock file: $LOCK_FILE"
    if ! flock -w "$LOCK_TIMEOUT" 9; then
        die "another start_store_cluster instance holds $LOCK_FILE"
    fi
    log "acquired lock: $LOCK_FILE"
}

check_ld_paths() {
    local host=$1
    local container=${2-$CONTAINER}
    local output cmd=""
    local -a parts=()
    local part

    [[ -n "$LD_LIBRARY_PATH_EXTRA" ]] || return 0
    IFS=':' read -r -a parts <<<"$LD_LIBRARY_PATH_EXTRA"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        cmd+="[ -d $(printf '%q' "$part") ] || { echo $(printf '%q' "missing LD_LIBRARY_PATH entry: $part"); exit 1; }; "
    done
    [[ -n "$cmd" ]] || return 0
    if ! output=$(run_on_host "$host" "$cmd" 0 "$container" 2>&1); then
        die "LD_LIBRARY_PATH check failed on $host${container:+ (container $container)}: ${output:-unknown error}"
    fi
}

check_hosts() {
    local -A seen=()
    local host container i
    for host in "${ENTRY_HOST[@]}"; do
        [[ -z "${seen[$host]:-}" ]] || continue
        seen[$host]=1
        container=""
        for i in "${!ENTRY_ROLE[@]}"; do
            if [[ "${ENTRY_HOST[$i]}" == "$host" ]]; then
                container=${ENTRY_CONTAINER[$i]}
                break
            fi
        done
        log "checking host $host${container:+ (container $container)}"
        run_on_host "$host" "true" 0 "" ||
            die "cannot reach host $host"
        run_on_host "$host" "${RUNTIME_PREFIX}command -v python3 >/dev/null 2>&1" 0 "$container" ||
            die "python3 is required on $host${container:+ (container $container)} for readiness checks"
        if ((KILL_EXISTING)); then
            run_on_host "$host" "command -v pkill >/dev/null 2>&1" 0 "$container" ||
                die "pkill (procps) is required on $host${container:+ (container $container)} for kill_existing; install procps or set kill_existing=0"
        fi
        check_ld_paths "$host" "$container"
    done
}

check_binary() {
    local host=$1
    local bin=$2
    local container=${3-$CONTAINER}
    local cmd output
    local rc=0

    cmd="${RUNTIME_PREFIX}bin=$(printf '%q' "$bin"); "
    cmd+='if [[ "$bin" != */* ]]; then bin=$(command -v "$bin") || { echo "binary not found in PATH"; exit 3; }; fi; '
    cmd+='[ -x "$bin" ] || { echo "binary is not executable"; exit 4; }; '
    cmd+='command -v ldd >/dev/null 2>&1 || { echo "ldd is not available"; exit 5; }; '
    cmd+='ldd_out=$(ldd "$bin" 2>&1); '
    cmd+="missing=\$(printf '%s\\n' \"\$ldd_out\" | awk '\$2==\"=>\" && \$3==\"not\" && \$4==\"found\" {m[\$1]=1; next} \$2==\"=>\" && \$3 ~ /^\\// {delete m[\$1]} END {for (x in m) print x}'); "
    cmd+='if [ -n "$missing" ]; then echo "missing shared libraries:"; echo "$missing"; exit 6; fi'

    output=$(run_on_host "$host" "$cmd" 0 "$container" 2>&1) || rc=$?
    if ((rc != 0)); then
        die "dependency check failed on $host${container:+ (container $container)} for $bin: ${output:-unknown error}
Install the missing packages or add their directories to ld_library_path."
    fi
}

check_all_binaries() {
    local i bin key
    local -A checked=()
    for i in "${!ENTRY_ROLE[@]}"; do
        if [[ "${ENTRY_ROLE[$i]}" == "master" ]]; then
            bin=$MASTER_BIN
        else
            bin=$CLIENT_BIN
        fi
        key="${ENTRY_HOST[$i]}:${ENTRY_CONTAINER[$i]}:$bin"
        [[ -z "${checked[$key]:-}" ]] || continue
        checked[$key]=1
        check_binary "${ENTRY_HOST[$i]}" "$bin" "${ENTRY_CONTAINER[$i]}"
    done
}

kill_existing() {
    ((KILL_EXISTING)) || return 0

    local -A seen=()
    local i host container key cmd
    for i in "${!ENTRY_ROLE[@]}"; do
        host=${ENTRY_HOST[$i]}
        container=${ENTRY_CONTAINER[$i]}
        key="$host:$container"
        [[ -z "${seen[$key]:-}" ]] || continue
        seen[$key]=1

        log "killing existing mooncake processes on $host${container:+ (container $container)}"
        cmd='command -v pkill >/dev/null 2>&1 || { echo "pkill is required to clean existing processes"; exit 1; }; '
        cmd+='pkill -TERM -x mooncake_master 2>/dev/null || true; '
        cmd+='pkill -TERM -x mooncake_test 2>/dev/null || true; '
        cmd+='pkill -TERM -x mooncake_client 2>/dev/null || true; '
        cmd+='sleep 2; '
        cmd+='pkill -KILL -x mooncake_master 2>/dev/null || true; '
        cmd+='pkill -KILL -x mooncake_test 2>/dev/null || true; '
        cmd+='pkill -KILL -x mooncake_client 2>/dev/null || true'
        run_on_host "$host" "$cmd" 0 "$container" ||
            die "failed to kill existing processes on $host${container:+ (container $container)}"
    done
}

entry_dir_for() { printf '%s/%s' "$RUN_DIR" "$(safe_name "$1")"; }
entry_log_for() { printf '%s/%s-%s.log' "$(entry_dir_for "$1")" "$2" "$3"; }
entry_pid_for() { printf '%s/%s-%s.pid' "$(entry_dir_for "$1")" "$2" "$3"; }

build_role_args() {
    local role=$1
    local ip=$2
    local port=$3
    local extra=$4
    local segment_size=${5:-}
    local local_buffer_size=${6:-}

    if [[ -z "$segment_size" ]]; then
        segment_size=$GLOBAL_SEGMENT_SIZE_BYTES
    fi
    local_buffer_size=$(effective_local_buffer_size "$local_buffer_size")

    ROLE_ARGS=()
    if [[ "$role" == "master" ]]; then
        ROLE_ARGS+=(--rpc_port="$port" --logtostderr=true)
    else
        ROLE_ARGS+=(
            --http-host="$HTTP_HOST"
            --http-port="$port"
            --http-threads="$HTTP_THREADS"
            --local-hostname="$ip"
            --metadata-server="$METADATA_SERVER"
            --master-server-addr="$MASTER_SERVER_ADDRESS"
            --protocol="$PROTOCOL"
        )
        # mooncake_test parses its arguments with CLI11, where "--flag=" (an
        # empty inline value) is treated as a missing value and the *next*
        # argument becomes the value. Passing --rdma-devices= with an empty
        # device_names would therefore swallow --global-segment-size, leaving
        # the client with segment size 0 and no mounted segment. Omit the flag
        # instead: an absent device list already means auto-selection/ignored.
        if [[ -n "$DEVICE_NAMES" ]]; then
            ROLE_ARGS+=(--rdma-devices="$DEVICE_NAMES")
        fi
        ROLE_ARGS+=(
            --global-segment-size="$segment_size"
            --local-buffer-size="$local_buffer_size"
            --min-put-size-mb="$MIN_PUT_SIZE_MB"
            --max-put-size-mb="$MAX_PUT_SIZE_MB"
        )
        if ((ENABLE_ZEROCOPY == 1)); then
            ROLE_ARGS+=(--enable-zerocopy
                --zerocopy-recv-pool-size-mb="$ZEROCOPY_RECV_POOL_MB")
        fi
    fi

    if [[ -n "$extra" ]]; then
        local -a extra_args=()
        read -r -a extra_args <<<"$extra"
        ROLE_ARGS+=("${extra_args[@]}")
    fi
}

quote_args() {
    local out=""
    local arg
    for arg in "$@"; do
        out+=" $(printf '%q' "$arg")"
    done
    printf '%s' "${out# }"
}

entry_running() {
    local host=$1
    local ip=$2
    local role=$3
    local port=$4
    local container=${5-$CONTAINER}
    local pid cmd

    ((DRY_RUN)) && return 1
    pid=$(entry_pid_for "$ip" "$role" "$port")
    cmd="pidfile=$(printf '%q' "$pid"); "
    cmd+='if [ -f "$pidfile" ]; then '
    cmd+='pid=$(cat "$pidfile"); kill -0 "$pid" 2>/dev/null; '
    cmd+='else false; fi'
    run_on_host "$host" "$cmd" 0 "$container" >/dev/null 2>&1
}

port_available() {
    local host=$1
    local port=$2
    local container=${3-$CONTAINER}
    local py cmd

    ((DRY_RUN)) && return 0
    py='import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0", int(sys.argv[1]))); s.close()'
    cmd="${RUNTIME_PREFIX}python3 -c $(printf '%q' "$py") $port"
    run_on_host "$host" "$cmd" 0 "$container" >/dev/null 2>&1
}

start_entry() {
    local i=$1
    local role=${ENTRY_ROLE[$i]}
    local host=${ENTRY_HOST[$i]}
    local ip=${ENTRY_IP[$i]}
    local container=${ENTRY_CONTAINER[$i]}
    local port=${ENTRY_PORT[$i]}
    local segment_size=${ENTRY_SEGMENT_SIZE[$i]}
    local local_buffer_size=${ENTRY_LOCAL_BUFFER_SIZE[$i]}
    local extra=${ENTRY_EXTRA[$i]}
    local bin dir log pid args_q cmd

    ENTRY_STARTED=0
    if entry_running "$host" "$ip" "$role" "$port" "$container"; then
        warn "$role on $host($ip):$port is already running; skipping"
        return 0
    fi
    if ! port_available "$host" "$port" "$container"; then
        die "port $port is unavailable on $host${container:+ (container $container)} (already in use, or python3 is missing)"
    fi

    if [[ "$role" == "master" ]]; then
        bin=$MASTER_BIN
    else
        bin=$CLIENT_BIN
    fi

    build_role_args "$role" "$ip" "$port" "$extra" "$segment_size" "$local_buffer_size"
    args_q=""
    if ((${#ROLE_ARGS[@]} > 0)); then
        args_q=$(quote_args "${ROLE_ARGS[@]}")
    fi

    dir=$(entry_dir_for "$ip")
    log=$(entry_log_for "$ip" "$role" "$port")
    pid=$(entry_pid_for "$ip" "$role" "$port")

    cmd="${RUNTIME_PREFIX}"
    cmd+="exec 9>&- 2>/dev/null || true; "
    cmd+="mkdir -p $(printf '%q' "$dir"); "
    cmd+="cd $(printf '%q' "$dir") || exit 1; "
    cmd+="nohup $(printf '%q' "$bin") $args_q "
    cmd+=">$(printf '%q' "$log") 2>&1 < /dev/null & "
    cmd+="echo \$! > $(printf '%q' "$pid")"

    log "starting $role on $host($ip)${container:+ [container $container]}:$port"
    log "  log: $log"
    if [[ "$role" == "client" ]]; then
        log "  protocol: $PROTOCOL${DEVICE_NAMES:+ (devices: $DEVICE_NAMES)}"
        log "  segment-size: $(format_size "${segment_size:-$GLOBAL_SEGMENT_SIZE_BYTES}")"
        log "  local-buffer-size: $(format_size "$(effective_local_buffer_size "$local_buffer_size")")"
    fi
    ENTRY_STARTED=1
    run_on_host "$host" "$cmd" 1 "$container"
}

wait_port() {
    local host=$1
    local ip=$2
    local port=$3
    local logfile=$4
    local role=$5
    local container=${6-$CONTAINER}
    local probe=$ip
    local py cmd
    local i

    py='import socket,sys; s=socket.socket(); s.settimeout(1); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()'
    cmd="${RUNTIME_PREFIX}python3 -c $(printf '%q' "$py") $(printf '%q' "$probe") $port"

    for ((i = 0; i < START_TIMEOUT; i++)); do
        if run_on_host "$host" "$cmd" 0 "$container" >/dev/null 2>&1; then
            log "ready: $host($ip):$port"
            return 0
        fi
        if ((!DRY_RUN)) && ! entry_running "$host" "$ip" "$role" "$port" "$container"; then
            warn "$role on $host($ip):$port exited before listening"
            run_on_host "$host" "tail -n 50 $(printf '%q' "$logfile")" 0 "$container" >&2 || true
            return 1
        fi
        sleep 1
    done

    warn "timeout waiting for $host($ip):$port after ${START_TIMEOUT}s"
    run_on_host "$host" "tail -n 50 $(printf '%q' "$logfile")" 0 "$container" >&2 || true
    return 1
}

wait_http_health() {
    local host=$1
    local ip=$2
    local port=$3
    local logfile=$4
    local container=${5-$CONTAINER}
    local probe=$ip
    local py cmd
    local i

    ((CLIENT_HEALTH_CHECK)) || return 0
    ((DRY_RUN)) && return 0
    py='import json,sys,urllib.request; o=urllib.request.build_opener(urllib.request.ProxyHandler({})); r=o.open("http://%s:%s/health" % (sys.argv[1], sys.argv[2]), timeout=2); d=json.loads(r.read()); sys.exit(0 if d.get("ready") is True else 1)'
    cmd="${RUNTIME_PREFIX}python3 -c $(printf '%q' "$py") $(printf '%q' "$probe") $port"

    for ((i = 0; i < START_TIMEOUT; i++)); do
        if run_on_host "$host" "$cmd" 0 "$container" >/dev/null 2>&1; then
            log "healthy: $host($ip):$port/health"
            return 0
        fi
        if ! entry_running "$host" "$ip" client "$port" "$container"; then
            warn "mooncake_test on $host($ip):$port exited before becoming healthy"
            run_on_host "$host" "tail -n 50 $(printf '%q' "$logfile")" 0 "$container" >&2 || true
            return 1
        fi
        sleep 1
    done

    warn "timeout waiting for http://$ip:$port/health after ${START_TIMEOUT}s"
    run_on_host "$host" "tail -n 50 $(printf '%q' "$logfile")" 0 "$container" >&2 || true
    return 1
}

start_all() {
    local i

    STARTED_ENTRIES=()
    for i in "${!ENTRY_ROLE[@]}"; do
        [[ "${ENTRY_ROLE[$i]}" == "master" ]] || continue
        start_entry "$i"
        if ((ENTRY_STARTED)); then
            STARTED_ENTRIES+=("$i")
        fi
    done
    for i in "${!ENTRY_ROLE[@]}"; do
        [[ "${ENTRY_ROLE[$i]}" == "master" ]] || continue
        wait_port "${ENTRY_HOST[$i]}" "${ENTRY_IP[$i]}" "${ENTRY_PORT[$i]}" \
            "$(entry_log_for "${ENTRY_IP[$i]}" master "${ENTRY_PORT[$i]}")" \
            master "${ENTRY_CONTAINER[$i]}"
    done

    for i in "${!ENTRY_ROLE[@]}"; do
        [[ "${ENTRY_ROLE[$i]}" == "client" ]] || continue
        start_entry "$i"
        if ((ENTRY_STARTED)); then
            STARTED_ENTRIES+=("$i")
        fi
    done
    for i in "${!ENTRY_ROLE[@]}"; do
        [[ "${ENTRY_ROLE[$i]}" == "client" ]] || continue
        wait_port "${ENTRY_HOST[$i]}" "${ENTRY_IP[$i]}" "${ENTRY_PORT[$i]}" \
            "$(entry_log_for "${ENTRY_IP[$i]}" client "${ENTRY_PORT[$i]}")" \
            client "${ENTRY_CONTAINER[$i]}"
        wait_http_health "${ENTRY_HOST[$i]}" "${ENTRY_IP[$i]}" "${ENTRY_PORT[$i]}" \
            "$(entry_log_for "${ENTRY_IP[$i]}" client "${ENTRY_PORT[$i]}")" \
            "${ENTRY_CONTAINER[$i]}"
    done
}

stop_entry() {
    local i=$1
    local role=${ENTRY_ROLE[$i]}
    local host=${ENTRY_HOST[$i]}
    local ip=${ENTRY_IP[$i]}
    local container=${ENTRY_CONTAINER[$i]}
    local port=${ENTRY_PORT[$i]}
    local pid cmd

    pid=$(entry_pid_for "$ip" "$role" "$port")
    cmd="pidfile=$(printf '%q' "$pid"); "
    cmd+='if [ -f "$pidfile" ]; then '
    cmd+='pid=$(cat "$pidfile"); '
    cmd+='if kill -0 "$pid" 2>/dev/null; then '
    cmd+='kill -TERM "$pid" 2>/dev/null || true; '
    cmd+="for _ in \$(seq 1 $STOP_TIMEOUT); do "
    cmd+='kill -0 "$pid" 2>/dev/null || break; sleep 1; '
    cmd+='done; '
    cmd+='if kill -0 "$pid" 2>/dev/null; then '
    cmd+='kill -KILL "$pid" 2>/dev/null || true; '
    cmd+='fi; '
    cmd+='fi; '
    cmd+='rm -f "$pidfile"; '
    cmd+='fi'

    log "stopping $role on $host($ip)${container:+ [container $container]}:$port"
    run_on_host "$host" "$cmd" 0 "$container"
}

do_stop() {
    local i rc=0
    for ((i = ${#ENTRY_ROLE[@]} - 1; i >= 0; i--)); do
        if ! stop_entry "$i"; then
            rc=1
        fi
    done
    return "$rc"
}

do_stop_started() {
    local j i rc=0
    for ((j = ${#STARTED_ENTRIES[@]} - 1; j >= 0; j--)); do
        i=${STARTED_ENTRIES[$j]}
        if ! stop_entry "$i"; then
            rc=1
        fi
    done
    return "$rc"
}

print_started_logs() {
    local j i host ip container role port logfile
    for ((j = ${#STARTED_ENTRIES[@]} - 1; j >= 0; j--)); do
        i=${STARTED_ENTRIES[$j]}
        host=${ENTRY_HOST[$i]}
        ip=${ENTRY_IP[$i]}
        container=${ENTRY_CONTAINER[$i]}
        role=${ENTRY_ROLE[$i]}
        port=${ENTRY_PORT[$i]}
        logfile=$(entry_log_for "$ip" "$role" "$port")
        printf '\n===== %s =====\n' "$logfile" >&2
        run_on_host "$host" "tail -n 50 $(printf '%q' "$logfile")" 0 "$container" >&2 || true
    done
}

print_status() {
    local i host ip container role port segment local_buffer pid cmd state
    printf '%-8s %-12s %-15s %-20s %-6s %-10s %-12s %s\n' \
        "ROLE" "SSH" "IP" "CONTAINER" "PORT" "SEGMENT" "LOCAL_BUF" "STATE"

    for i in "${!ENTRY_ROLE[@]}"; do
        role=${ENTRY_ROLE[$i]}
        host=${ENTRY_HOST[$i]}
        ip=${ENTRY_IP[$i]}
        container=${ENTRY_CONTAINER[$i]}
        port=${ENTRY_PORT[$i]}
        segment="-"
        local_buffer="-"
        if [[ "$role" == "client" ]]; then
            segment=$(format_size "${ENTRY_SEGMENT_SIZE[$i]:-$GLOBAL_SEGMENT_SIZE_BYTES}")
            local_buffer=$(format_size "$(effective_local_buffer_size "${ENTRY_LOCAL_BUFFER_SIZE[$i]}")")
        fi
        pid=$(entry_pid_for "$ip" "$role" "$port")
        cmd="pidfile=$(printf '%q' "$pid"); "
        cmd+='if [ -f "$pidfile" ]; then '
        cmd+='pid=$(cat "$pidfile"); '
        cmd+='if kill -0 "$pid" 2>/dev/null; then '
        cmd+='echo "running pid=$pid"; '
        cmd+='else echo stopped; fi; '
        cmd+='else echo stopped; fi'

        if ! state=$(run_on_host "$host" "$cmd" 0 "$container" 2>/dev/null); then
            state="unreachable"
        fi
        printf '%-8s %-12s %-15s %-20s %-6s %-10s %-12s %s\n' \
            "$role" "$host" "$ip" "${container:--}" "$port" "$segment" "$local_buffer" "$state"
    done
}

cleanup() {
    local rc=$?
    set +e
    trap - EXIT
    if ((rc != 0 && STARTED == 1)); then
        warn "start failed; stopping processes started by this run"
        STARTED=0
        do_stop_started
        print_started_logs
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main() {
    parse_args "$@"
    parse_config
    validate_config
    build_ssh_cmd
    build_runtime_prefix
    check_local_tools

    case "$ACTION" in
        start|stop|restart)
            acquire_lock
            ;;
    esac

    case "$ACTION" in
        start)
            log "config: $CONFIG_FILE"
            check_hosts
            check_all_binaries
            kill_existing
            STARTED=1
            start_all
            STARTED=0
            log "cluster started"
            ;;
        stop)
            do_stop
            log "cluster stopped"
            ;;
        restart)
            log "config: $CONFIG_FILE"
            do_stop || true
            check_hosts
            check_all_binaries
            kill_existing
            STARTED=1
            start_all
            STARTED=0
            log "cluster restarted"
            ;;
        status)
            print_status
            ;;
        check)
            check_hosts
            check_all_binaries
            log "all dependency checks passed"
            ;;
    esac
}

main "$@"

