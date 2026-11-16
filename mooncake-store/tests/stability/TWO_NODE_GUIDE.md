# Mooncake Store 两节点手动编译与测试指南

本文面向“手动编译 + 两个节点直接跑进程”的场景，不依赖 Docker、K8s 或 Helm。
目标是用两个节点验证：

- Store master / client / HTTP KV 工具能正常启动；
- Node B 的测试进程能通过 Node A 的 master 读写跨节点 segment；
- ASan/LSan 插桩版能正常退出并收集检测报告；
- 出现问题时能快速定位是编译、网络、segment 还是 ASan 环境问题。

---

## 1. 拓扑与端口

推荐先用 **Topology A**，它保证数据面跨节点：

```text
Node A (master + storage)                  Node B (test)
┌──────────────────────────────┐          ┌──────────────────────────────┐
│ mooncake_master               │          │ mooncake_test                │
│   RPC        :50051           │          │   HTTP KV    :18080          │
│   HTTP meta  :8080            │          │                              │
│   metrics    :9003            │          │                              │
│ mooncake_client               │          │                              │
│   RPC        :50052           │          │                              │
│   segment    256MB            │          │                              │
└──────────────────────────────┘          └──────────────────────────────┘
          ▲                                         │
          └────────── 控制面 + 数据面 ──────────────┘
```

- Node A 提供 master、HTTP metadata、metrics 和一个存储 segment；
- Node B 只运行测试工具，不贡献 segment；
- 因此 Node B 的 `put/get` 必须访问 Node A 的 segment，数据面是跨节点的；
- 这是最简单的两节点验证方式。

> `run_stability.sh smoke` 是单机 all-in-one 模式；两节点请按本文手动启动各角色。

如果需要验证“两个节点都贡献 segment”，再使用 **Topology B**：

```text
Node A: master + client A (segment A)
Node B: client B (segment B) + test (pure consumer)
```

Topology B 会在第 7 节补充。

### 端口约定

| 节点 | 端口 | 用途 |
|---|---|---|
| Node A | `50051/tcp` | master RPC |
| Node A | `8080/tcp` | master 内置 HTTP metadata |
| Node A | `9003/tcp` | master metrics/admin |
| Node A | `50052/tcp` | client RPC（Topology B 或手动调试用） |
| Node B | `18080/tcp` | mooncake_test HTTP KV |
| Node B | `50052/tcp` | client RPC（Topology B 时使用） |
| 两节点之间 | 高位 TCP 端口 | Transfer Engine TCP 动态端口；防火墙需放通同网段 |

> 如果宿主机已有服务占用端口，修改本文中的 `50051/8080/9003/18080`，并保持所有进程一致。

---

## 2. 前置条件

两个节点都需要：

- Linux x86_64，相同或兼容的 OS / glibc；
- CMake ≥ 3.16、C++20 编译器；
- Mooncake 依赖（可用仓库的 `dependencies.sh` 安装）；
- 相同的源码版本；
- 相同的构建 profile（`USE_SHCA`、`USE_HYGON`、`USE_TCP` 等）；
- 如果使用 RDMA/SHCA：两个节点都要有可用的 RDMA 设备、SHCA 用户态库、DTK/hyhal。

### 2.1 安装依赖

在节点 A 和节点 B 上分别执行：

```bash
cd /path/to/mooncake-das
sudo bash dependencies.sh -y
```

如果本机已有依赖，可以跳过。

### 2.2 检查 RDMA（仅 RDMA/SHCA 模式）

```bash
ibv_devices
ibv_devinfo
```

期望能看到实际设备（例如 `shca_0`）。如果 `ibv_devices` 为空，先不要继续，
否则 client 会启动失败或访问不到 segment。

### 2.3 检查 DTK/hyhal（DCU 模式）

```bash
ls -d /opt/dtk /opt/dtk/cuda/cuda-12/targets/x86_64-linux/include /opt/hyhal
```

不同机器的 DTK 路径可能不同，请以实际路径替换本文的：

```text
/opt/dtk/cuda/cuda-12/targets/x86_64-linux/include
/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib
```

---

## 3. 手动编译

### 3.1 推荐：两个节点分别编译

两个节点架构和依赖通常一致，分别编译最省心，避免 ASan 二进制、RPATH、
DTK/hyhal 版本不一致。

#### 默认稳定性构建（无 ASan）

在节点 A 和节点 B 上执行同样的命令：

```bash
cd /path/to/mooncake-das

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

#### ASan 稳定性构建

```bash
cd /path/to/mooncake-das

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

#### DCU / SHCA 附加参数

在 SHCA 机器上，把下面这些参数追加到上面的 `cmake -S` 命令中：

```bash
-DUSE_SHCA=ON \
-DUSE_HYGON=ON \
-DYLT_ENABLE_IBV=OFF \
-DDTK_INCLUDE_DIR=/opt/dtk/cuda/cuda-12/targets/x86_64-linux/include \
-DDTK_LIB_DIR=/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib
```

产物：

```text
build-stability/mooncake-store/src/mooncake_master
build-stability/mooncake-store/src/mooncake_client
build-stability/mooncake-store/tests/stability/mooncake-test/mooncake_test
```

或 ASan 目录下的同名产物：

```text
build-stability-asan/mooncake-store/...
```

`ENABLE_ASAN` 和 `BUILD_STORE_STABILITY_TESTS` 是独立的：

- `BUILD_STORE_STABILITY_TESTS` 控制是否构建稳定性工具；
- `ENABLE_ASAN` 控制是否加 `-fsanitize=address/leak`；
- `DETECT_TOOL=asan|none` 控制运行时是否注入 ASan/LSan 环境。

### 3.2 可选：只在 Node A 编译，再分发到 Node B

只有在两个节点 OS、glibc、DTK、SHCA 库一致时才建议这样做。

```bash
# 在 Node A 编译完成后
rsync -a /data/mooncake/build-stability-asan/ \
  nodeB:/data/mooncake/build-stability-asan/
```

然后在 Node B 检查动态库：

```bash
export BUILD_DIR=/data/mooncake/build-stability-asan
export LD_LIBRARY_PATH="$BUILD_DIR/mooncake-common:$BUILD_DIR/mooncake-common/etcd:$BUILD_DIR/mooncake-store/src:$BUILD_DIR/mooncake-transfer-engine/src:/opt/dtk/lib:/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib:/opt/hyhal/lib:$LD_LIBRARY_PATH"

ldd "$BUILD_DIR/mooncake-store/src/mooncake_master" | grep 'not found' || true
ldd "$BUILD_DIR/mooncake-store/src/mooncake_client" | grep 'not found' || true
ldd "$BUILD_DIR/mooncake-store/tests/stability/mooncake-test/mooncake_test" | grep 'not found' || true
```

如果出现 `not found`，优先在 Node B 本地重新编译，或补齐对应的 DTK/SHCA/系统库。

### 3.3 编译后自检

```bash
export BUILD_DIR=/data/mooncake/build-stability-asan
export LD_LIBRARY_PATH="$BUILD_DIR/mooncake-common:$BUILD_DIR/mooncake-common/etcd:$BUILD_DIR/mooncake-store/src:$BUILD_DIR/mooncake-transfer-engine/src:/opt/dtk/lib:/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib:/opt/hyhal/lib:$LD_LIBRARY_PATH"

"$BUILD_DIR/mooncake-store/src/mooncake_master" --help >/dev/null
"$BUILD_DIR/mooncake-store/src/mooncake_client" --help >/dev/null
"$BUILD_DIR/mooncake-store/tests/stability/mooncake-test/mooncake_test" --help >/dev/null
```

ASan profile 还可以确认链接了 `libasan`：

```bash
ldd "$BUILD_DIR/mooncake-store/src/mooncake_master" | grep libasan
ldd "$BUILD_DIR/mooncake-store/src/mooncake_client" | grep libasan
ldd "$BUILD_DIR/mooncake-store/tests/stability/mooncake-test/mooncake_test" | grep libasan
```

---

## 4. 两节点公共环境变量

下面的变量需要在 Node A 和 Node B 上分别设置。把 IP、路径替换成实际值。

### Node A

```bash
export NODE_A_IP=10.0.0.10
export NODE_B_IP=10.0.0.11
export MASTER_IP=$NODE_A_IP

export REPO_ROOT=/path/to/mooncake-das
export BUILD_DIR=/data/mooncake/build-stability-asan
export RUN_ROOT=/data/mooncake/stability

export MASTER_BIN=$BUILD_DIR/mooncake-store/src/mooncake_master
export CLIENT_BIN=$BUILD_DIR/mooncake-store/src/mooncake_client
export TEST_BIN=$BUILD_DIR/mooncake-store/tests/stability/mooncake-test/mooncake_test
export LSAN_SUPP=$REPO_ROOT/mooncake-store/tests/stability/lsan.supp

export LD_LIBRARY_PATH="$BUILD_DIR/mooncake-common:$BUILD_DIR/mooncake-common/etcd:$BUILD_DIR/mooncake-store/src:$BUILD_DIR/mooncake-transfer-engine/src:/opt/dtk/lib:/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib:/opt/hyhal/lib:$LD_LIBRARY_PATH"

mkdir -p "$RUN_ROOT/logs" "$RUN_ROOT/pids"
```

### Node B

```bash
export NODE_A_IP=10.0.0.10
export NODE_B_IP=10.0.0.11
export MASTER_IP=$NODE_A_IP

export REPO_ROOT=/path/to/mooncake-das
export BUILD_DIR=/data/mooncake/build-stability-asan
export RUN_ROOT=/data/mooncake/stability

export CLIENT_BIN=$BUILD_DIR/mooncake-store/src/mooncake_client
export TEST_BIN=$BUILD_DIR/mooncake-store/tests/stability/mooncake-test/mooncake_test
export LSAN_SUPP=$REPO_ROOT/mooncake-store/tests/stability/lsan.supp

export LD_LIBRARY_PATH="$BUILD_DIR/mooncake-common:$BUILD_DIR/mooncake-common/etcd:$BUILD_DIR/mooncake-store/src:$BUILD_DIR/mooncake-transfer-engine/src:/opt/dtk/lib:/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib:/opt/hyhal/lib:$LD_LIBRARY_PATH"

mkdir -p "$RUN_ROOT/logs" "$RUN_ROOT/pids"
```

### ASan/LSan 环境

每个进程使用独立的 `log_path`，避免多个进程互相覆盖：

```bash
# master（Node A）
export ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_path=$RUN_ROOT/logs/asan.master"
export LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0"

# client（Node A / Node B）
export ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_path=$RUN_ROOT/logs/asan.client-a"
export LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0"

# test（Node B）
export ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_path=$RUN_ROOT/logs/asan.test"
export LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0"
```

ASan 的 `log_path` 会自动追加 `.<pid>`，所以同一角色重启不会覆盖旧报告。

如果只是做性能对照，可以关闭泄漏检测：

```bash
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=0:abort_on_error=0:log_path=$RUN_ROOT/logs/asan.test"
```


---

## 5. 启动 Node A：master + client

### 5.1 启动 master

```bash
cd "$RUN_ROOT"

nohup env \
  ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_path=$RUN_ROOT/logs/asan.master" \
  LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0" \
  "$MASTER_BIN" \
    --rpc_port=50051 \
    --rpc_address=0.0.0.0 \
    --enable_http_metadata_server=true \
    --http_metadata_server_host=0.0.0.0 \
    --http_metadata_server_port=8080 \
    --metrics_port=9003 \
    --enable_metric_reporting=true \
    --default_kv_lease_ttl=60000 \
    --allocation_strategy=free_ratio_first \
    --eviction_ratio=0.1 \
    --eviction_high_watermark_ratio=0.9 \
    --cluster_id=mooncake_two_node \
    --logtostderr=true \
  > "$RUN_ROOT/logs/master.log" 2>&1 &

echo $! > "$RUN_ROOT/pids/master.pid"
```

检查：

```bash
sleep 3
tail -80 "$RUN_ROOT/logs/master.log"
```

期望看到：

```text
Master service started on port 50051
Master admin server started on port 9003
Restore lifecycle -> Serving
```

健康检查：

```bash
curl -s http://$MASTER_IP:9003/health
curl -s http://$MASTER_IP:9003/role
curl -s http://$MASTER_IP:9003/metrics | head
```

### 5.2 启动 Node A 的 client（贡献 segment）

```bash
cd "$RUN_ROOT"

nohup env \
  ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_path=$RUN_ROOT/logs/asan.client-a" \
  LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0" \
  "$CLIENT_BIN" \
    --host="$NODE_A_IP" \
    --port=50052 \
    --metadata_server="http://$MASTER_IP:8080/metadata" \
    --master_server_address="$MASTER_IP:50051" \
    --protocol=rdma \
    --device_names=shca_0 \
    --global_segment_size=256MB \
    --local_buffer_size=64MB \
    --tenant_id=default \
  > "$RUN_ROOT/logs/client-a.log" 2>&1 &

echo $! > "$RUN_ROOT/pids/client-a.pid"
```

TCP 模式把下面两行替换为：

```bash
    --protocol=tcp \
    --device_names= \
```

检查：

```bash
sleep 3
tail -80 "$RUN_ROOT/logs/client-a.log"
```

期望看到：

```text
Successfully created client
Mounting segment: ...
Starting real client service on $NODE_A_IP:50052
```

`Mounting segment` 出现之前，Node B 的 `put` 可能返回没有可用 segment，属于启动顺序问题。


---

## 6. 启动 Node B：test

Node B 只启动测试工具，作为纯 consumer；数据落在 Node A 的 segment 上，
因此数据面是跨节点的。

```bash
cd "$RUN_ROOT"

nohup env \
  ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_path=$RUN_ROOT/logs/asan.test" \
  LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0" \
  "$TEST_BIN" \
    --http-host=0.0.0.0 \
    --http-port=18080 \
    --http-threads=8 \
    --local-hostname="$NODE_B_IP" \
    --metadata-server="http://$MASTER_IP:8080/metadata" \
    --master-server-addr="$MASTER_IP:50051" \
    --protocol=rdma \
    --rdma-devices=shca_0 \
    --global-segment-size=0 \
    --local-buffer-size=67108864 \
    --min-put-size-mb=1 \
    --max-put-size-mb=16 \
  > "$RUN_ROOT/logs/test.log" 2>&1 &

echo $! > "$RUN_ROOT/pids/test.pid"
```

TCP 模式把下面两行替换为：

```bash
    --protocol=tcp \
    --rdma-devices= \
```

检查：

```bash
sleep 3
tail -80 "$RUN_ROOT/logs/test.log"
curl -s http://127.0.0.1:18080/health
```

期望：

```text
KvStoreClient setup succeeded
Random value cache initialized
```

`/health` 返回类似：

```json
{"ready":true,"status":"healthy",...}
```

如果没有 ready，先检查 Node B 是否能访问 Node A 的 `8080` 和 `50051`：

```bash
python3 - <<'PY'
import socket
for host, port in [("10.0.0.10", 8080), ("10.0.0.10", 50051)]:
    sock = socket.socket()
    sock.settimeout(2)
    try:
        sock.connect((host, port))
        print(f"{host}:{port} OK")
    except OSError as exc:
        print(f"{host}:{port} FAILED: {exc}")
    finally:
        sock.close()
PY
```

---

## 7. 功能验证

以下命令在 Node B（或任意能访问 Node B 的机器）执行。

```bash
TEST_URL=http://$NODE_B_IP:18080
```

### 7.1 health

```bash
curl -s "$TEST_URL/health"
```

### 7.2 put / get / exist

```bash
curl -s -X POST "$TEST_URL/api/kv" \
  -H 'Content-Type: application/json' \
  -d '{"operator":"put","key":"two_node_1","size":"1.0"}'

curl -s -X POST "$TEST_URL/api/kv" \
  -H 'Content-Type: application/json' \
  -d '{"operator":"get","key":"two_node_1","verify_data":true}'

curl -s -X POST "$TEST_URL/api/kv" \
  -H 'Content-Type: application/json' \
  -d '{"operator":"exist","key":"two_node_1"}'
```

期望：

- `put`：`"code":0`
- `get`：`"code":0` 且 `"data_valid":true`
- `exist`：`"exists":true` 或 `"code":1`

### 7.3 batch

```bash
curl -s -X POST "$TEST_URL/api/kv" \
  -H 'Content-Type: application/json' \
  -d '{"operator":"batch_put","key":"two_node_b1,two_node_b2,two_node_b3","size":"1.0"}'

curl -s -X POST "$TEST_URL/api/kv" \
  -H 'Content-Type: application/json' \
  -d '{"operator":"batch_get","key":"two_node_b1,two_node_b2,two_node_b3","verify_data":true}'
```

期望：

- `batch_put`：`"success":3`
- `batch_get`：`"success":3`，且 `validation_details` 中每项校验通过

### 7.4 性能接口

```bash
curl -s "$TEST_URL/api/performance"
curl -s -X POST "$TEST_URL/api/reset"
```

### 7.5 确认跨节点

在 Node B 上执行 `put` 后，到 Node A 查看 master 的 segment/key 指标：

```bash
curl -s http://$MASTER_IP:9003/metrics | grep -E \
  'master_(total_capacity_bytes|allocated_bytes|key_count|active_clients)'
```

Topology A 只有一个 segment 在 Node A，因此 Node B 的读写必然经过网络访问 Node A。
如果 `allocated_bytes` 增长、`key_count` 增长，说明数据已经落到 Node A。

### 7.6 可选：两个节点都贡献 segment（Topology B）

在 Node B 再启动一个 client：

```bash
nohup env \
  ASAN_OPTIONS="detect_leaks=1:halt_on_error=0:abort_on_error=0:print_stats=1:log_path=$RUN_ROOT/logs/asan.client-b" \
  LSAN_OPTIONS="suppressions=$LSAN_SUPP:print_suppressions=0" \
  "$CLIENT_BIN" \
    --host="$NODE_B_IP" \
    --port=50052 \
    --metadata_server="http://$MASTER_IP:8080/metadata" \
    --master_server_address="$MASTER_IP:50051" \
    --protocol=rdma \
    --device_names=shca_0 \
    --global_segment_size=256MB \
    --local_buffer_size=64MB \
    --tenant_id=default \
  > "$RUN_ROOT/logs/client-b.log" 2>&1 &

echo $! > "$RUN_ROOT/pids/client-b.pid"
```

然后重复第 7.2/7.3 的 put/get。master 的 `active_clients` 应变为 2，
`total_capacity_bytes` 应增加约 256MB。此时数据可能落在 A 或 B 的 segment，
可以进一步验证跨节点和本地 segment 两种路径。


---

## 8. 稳定性/压测场景

### 8.1 简单循环压测（不依赖 Python binding）

在 Node B 上循环执行 put/get，观察是否出现失败、ASan 报错或内存增长：

```bash
TEST_URL=http://$NODE_B_IP:18080

for i in $(seq 1 200); do
  curl -s -m 20 -X POST "$TEST_URL/api/kv" \
    -H 'Content-Type: application/json' \
    -d "{\"operator\":\"put\",\"key\":\"loop_$i\",\"size\":\"4.0\"}" \
    >/dev/null || { echo "put failed at $i"; break; }

  curl -s -m 20 -X POST "$TEST_URL/api/kv" \
    -H 'Content-Type: application/json' \
    -d "{\"operator\":\"get\",\"key\":\"loop_$i\",\"verify_data\":true}" \
    | grep -q '"data_valid":true' || { echo "verify failed at $i"; break; }
done
```

如果中途失败，保留 Node B 的 `logs/test.log` 和 `logs/asan.test.*`，
不要立即重启进程。

### 8.2 可选：使用 store_kv_bench.py

如果 Node B 已安装 Mooncake Python 绑定（`import mooncake.store` 成功），
可以直接用 benchmark 做固定次数校验：

```bash
cd /path/to/mooncake-das

export MASTER_IP=10.0.0.10
export NODE_B_IP=10.0.0.11
export METADATA_URL="http://$MASTER_IP:8080/metadata"

python3 mooncake-store/benchmarks/store_kv_bench.py \
  --scenario verify_write \
  --local-hostname="$NODE_B_IP:50071" \
  --metadata-server="$METADATA_URL" \
  --master-server="$MASTER_IP:50051" \
  --protocol=rdma \
  --device-name=shca_0 \
  --global-segment-size=268435456 \
  --local-buffer-size=67108864 \
  --nr-objects=256 \
  --value-size=4096 \
  --key-prefix=two_node_bench \
  --pattern=0xA5 \
  --verify \
  --output-dir=/data/mooncake/stability/bench
```

TCP 模式改为：

```bash
  --protocol=tcp \
  --device-name= \
```

如果 Python 绑定不在系统路径，可以设置：

```bash
export PYTHONPATH=$BUILD_DIR/mooncake-integration:$PYTHONPATH
```

但要注意：**Python 进程的 `LD_LIBRARY_PATH` 不要包含 ASan 构建目录**，
否则会报：

```text
ASan runtime does not come first in initial library list
```

只保留 DTK/hyhal 等运行库路径即可：

```bash
export LD_LIBRARY_PATH="/opt/dtk/lib:/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib:/opt/hyhal/lib:$LD_LIBRARY_PATH"
```

### 8.3 故障恢复观察（可选）

先保持 Node B 的 test 运行，然后在 Node A 停止 client：

```bash
kill -TERM "$(cat $RUN_ROOT/pids/client-a.pid)"
```

观察：

- Node B 的 put 是否开始失败（没有可用 segment / RPC 失败）；
- 重新启动 Node A client 后，Node B 是否恢复；
- master `/metrics` 的 `active_clients` 是否先降后升；
- ASan 日志是否出现真正的内存错误。

这不是 HA 测试；单个 master 或单个 client 重启不会自动迁移已有数据，
主要用于验证客户端重连和稳定性，而不是高可用语义。

---

## 9. 停止进程与检查 ASan 报告

### 9.1 Node B 先停 test

```bash
kill -TERM "$(cat $RUN_ROOT/pids/test.pid)" 2>/dev/null || true
sleep 10
```

### 9.2 Node A 停 client、master

```bash
kill -TERM "$(cat $RUN_ROOT/pids/client-a.pid)" 2>/dev/null || true
kill -TERM "$(cat $RUN_ROOT/pids/master.pid)" 2>/dev/null || true
sleep 10
```

如果进程没有退出：

```bash
kill -KILL "$(cat $RUN_ROOT/pids/test.pid)" 2>/dev/null || true
kill -KILL "$(cat $RUN_ROOT/pids/client-a.pid)" 2>/dev/null || true
kill -KILL "$(cat $RUN_ROOT/pids/master.pid)" 2>/dev/null || true
```

> 不要一开始就用 `kill -9`。LSan 在进程正常退出时才会汇总泄漏，
> SIGKILL 会丢失泄漏报告。

### 9.3 检查 ASan/LSan

```bash
grep -R -E \
  'ERROR: (AddressSanitizer|LeakSanitizer)|SUMMARY: AddressSanitizer: [1-9][0-9]* byte' \
  "$RUN_ROOT/logs"/asan.* 2>/dev/null
```

- 没有输出：未发现 ASan/LSan 错误；
- 有 `Direct leak` / `ERROR: LeakSanitizer`：记录完整栈；
- 有 `heap-buffer-overflow` / `heap-use-after-free`：记录完整栈和复现步骤。

单个报告示例：

```bash
sed -n '1,120p' "$RUN_ROOT/logs/asan.test.12345"
```

不要只看 `SUMMARY: AddressSanitizer: 0 byte(s) leaked`，它表示没有泄漏；
需要关注非零 byte 数和 `ERROR:` 行。

### 9.4 常用观测

```bash
# Node A
curl -s http://$MASTER_IP:9003/metrics | grep -E \
  'master_(total_capacity_bytes|allocated_bytes|key_count|active_clients|evicted_key_count)'

# Node B
curl -s http://127.0.0.1:18080/api/performance

# 进程内存
ps -o pid,rss,vsz,cmd -p \
  "$(cat $RUN_ROOT/pids/test.pid)" \
  "$(cat $RUN_ROOT/pids/client-a.pid)" \
  "$(cat $RUN_ROOT/pids/master.pid)"
```


---

## 10. 常见问题

### 10.1 Node B 启动 test 后 `/health` 不 ready

检查顺序：

1. Node B 能否访问 Node A 的 `8080` 和 `50051`；
2. Node A 的 master 日志是否有 `Master service started`；
3. Node A 的 client 是否已经 `Mounting segment`；
4. `--metadata-server` 是否写成 `http://$MASTER_IP:8080/metadata`；
5. `--master-server-addr` 是否写成 `$MASTER_IP:50051`。

### 10.2 `Connection refused` / `No route to host`

- master 没有监听在 `0.0.0.0`；
- 防火墙拦截 `50051/8080/9003`；
- Node B 用了 `127.0.0.1` 而不是 Node A 的 IP；
- `--rpc_address` 没设成 `0.0.0.0`。

### 10.3 `put` 返回没有可用 segment

典型日志：

```text
SEGMENT_NOT_FOUND
NO_AVAILABLE_HANDLE
```

原因通常是：

- Node A 的 `mooncake_client` 还没启动；
- client 的 `--global_segment_size` 太小；
- client 启动失败，没有完成 `Mounting segment`；
- master 和 client 的 `--protocol`、`--device_names` 不一致。

Topology A 必须确保 Node A 的 client 正常挂载 segment，因为 Node B 是纯 consumer。

### 10.4 RDMA 初始化失败

先检查：

```bash
ibv_devices
ibv_devinfo
```

如果看不到 `shca_0`：

- 节点没有 SHCA 用户态库 / `shca.driver`；
- 没有挂载 `/dev/infiniband`；
- 没有 `--privileged`（容器场景）；
- 没有正确设置 `LD_LIBRARY_PATH`。

如果只是验证功能，可以先把 `--protocol` 改成 `tcp`，确认控制面和 KV 逻辑正常，
再回到 RDMA 排查。

### 10.5 `libcudart.so.12` / `libgalaxyhip.so.5` not found

在 `LD_LIBRARY_PATH` 中加入：

```text
/opt/dtk/lib
/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib
/opt/hyhal/lib
```

不同机器的 DTK 路径可能不同，按实际路径调整。

### 10.6 `Address already in use`（9003 或 8080）

本机已有另一个 master 或 metadata 服务占用端口。修改：

```text
--http_metadata_server_port
--metrics_port
```

并同步修改所有 client/test 的 `--metadata-server`。

### 10.7 `ASan runtime does not come first`

说明 Python 或非 ASan 进程加载了 ASan 插桩的构建库。

- 不要给 `python3` 设置包含 `build-stability*/mooncake-store/src` 的 `LD_LIBRARY_PATH`；
- 原生进程需要这些路径，Python benchmark 不需要；
- 使用 `mooncake-store/tests/stability/run_stability.sh bench` 时脚本会自动处理，
  手动运行时需要自己区分。

### 10.8 编译时 `cuda.h: No such file or directory`

`USE_HYGON=ON` 需要显式指定 DTK 头文件和库目录：

```bash
DTK_INCLUDE_DIR=/opt/dtk/cuda/cuda-12/targets/x86_64-linux/include
DTK_LIB_DIR=/opt/dtk/cuda/cuda-12/targets/x86_64-linux/lib
```

如果使用默认 `cuda-11` 布局，按实际 DTK 目录调整。

### 10.9 编译时 `U17` / `lid` 类型错误

在同时安装 SHCA 头文件的机器上，不要用 `USE_SHCA=OFF` 构建 stock RDMA 路径。
使用：

```bash
USE_SHCA=ON
YLT_ENABLE_IBV=OFF
```

---

## 11. 最小验收清单

- [ ] 两个节点都能找到 `mooncake_master` / `mooncake_client` / `mooncake_test`
- [ ] `ldd` 无 `not found`
- [ ] ASan profile 的三个二进制都链接 `libasan`
- [ ] Node A master 日志出现 `Master service started`
- [ ] Node A master 日志出现 `Master admin server started`
- [ ] Node A client 日志出现 `Mounting segment`
- [ ] Node B test `/health` 返回 `ready:true`
- [ ] `put` 返回 `code:0`
- [ ] `get` 返回 `data_valid:true`
- [ ] `exist` 返回 `exists:true`
- [ ] `batch_put` / `batch_get` 成功
- [ ] master `/metrics` 的 `active_clients` 和 `key_count` 有变化
- [ ] 停止进程后 ASan 日志无 `ERROR:` / 非零泄漏
- [ ] 测试结束后没有残留 `mooncake_master` / `mooncake_client` / `mooncake_test`

---

## 12. 附录：变量速查

| 变量 | 示例 | 说明 |
|---|---|---|
| `NODE_A_IP` | `10.0.0.10` | master 节点 IP |
| `NODE_B_IP` | `10.0.0.11` | test 节点 IP |
| `MASTER_IP` | `10.0.0.10` | master RPC + HTTP metadata 地址 |
| `BUILD_DIR` | `/data/mooncake/build-stability-asan` | 构建目录 |
| `RUN_ROOT` | `/data/mooncake/stability` | 日志、PID 根目录 |
| `MASTER_PORT` | `50051` | master RPC |
| `METRICS_PORT` | `9003` | master metrics/admin |
| `METADATA_PORT` | `8080` | master 内置 HTTP metadata |
| `CLIENT_PORT` | `50052` | client RPC |
| `TEST_HTTP_PORT` | `18080` | test HTTP KV |
| `PROTOCOL` | `rdma` / `tcp` | 传输协议 |
| `DEVICE_NAME` | `shca_0` | RDMA 设备名 |
| `GLOBAL_SEGMENT_SIZE` | `256MB` | client 贡献的 segment |
| `LOCAL_BUFFER_SIZE` | `64MB` | client 本地缓冲区 |

### 相关脚本

| 路径 | 用途 |
|---|---|
| `mooncake-store/tests/stability/run_role.sh` | 单角色启动，适合容器/多节点 |
| `mooncake-store/tests/stability/run_stability.sh` | 单机 all-in-one smoke/bench |
| `mooncake-store/tests/stability/lsan.supp` | LSan 抑制规则 |
| `mooncake-store/benchmarks/store_kv_bench.py` | Python 负载/校验工具 |
| `scripts/hygon/start_store_cluster.sh` | 按配置文件一键检查依赖并启动/停止多节点 master/mooncake_test |
| `scripts/hygon/store_cluster.conf.example` | 多节点拓扑配置样例 |

### 一键启动多节点（Hygon）

```bash
cp scripts/hygon/store_cluster.conf.example scripts/hygon/store_cluster.conf
# 编辑 store_cluster.conf 中的 host/role/port、client_bin（mooncake_test 路径）
# 以及可选的 SSH/DTK 参数

bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf check
bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf start
bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf status
bash scripts/hygon/start_store_cluster.sh -c scripts/hygon/store_cluster.conf stop
```

配置中先用 `host` 映射主机名、节点 IP 和 Docker 容器名：

```text
host <主机名> <节点IP> <docker名|->
```

然后每一行是一个实例：

```text
master <主机名> <port> [额外参数...]
client <主机名> <http_port> [segment_size] [local_buffer_size] [额外参数...]
```

`client` 角色启动的是 `mooncake_test`（HTTP KV 测试工具），不是
`mooncake_client`；`<http_port>` 是 `mooncake_test` 的 HTTP 端口。
`segment_size`/`local_buffer_size` 支持字节数或 `K/M/G/T` 后缀，默认分别为
`4GB` / `256MB`，省略时使用全局 `global_segment_size` / `local_buffer_size`。
同一节点要跑多个 client 时重复写多行、使用不同 HTTP 端口即可，每个 client
可以有自己的 `segment_size` 和 `local_buffer_size`。`segment_size` 是贡献给
集群的存储，`local_buffer_size` 是 client 本地的传输暂存池。脚本会先启动
master 并等待端口，再启动 client；`stop` 按相反顺序停止。`local` /
`localhost` / `127.0.0.1` 表示在脚本所在机器本地执行：配置了容器名时本地也走
`docker exec`，没有容器名时直接在当前环境执行。其余主机名/IP 通过 SSH 和
（配置了容器时）`docker exec`。

`check` 会在启动前逐节点检查：SSH 连通性、容器内 `python3`、
`LD_LIBRARY_PATH` 中的目录、二进制是否存在且可执行，以及 `ldd` 是否有
未解析的共享库；`start` 会自动执行同样的检查，并额外检查服务端口是否空闲。
`start` 还会等待 `mooncake_test` 的 `/health` 返回 `ready=true`，并在启动失败时
自动停止本次启动的进程、打印日志。
`kill_existing=1`（默认）会在依赖检查通过后、启动前，通过
`pkill -x mooncake_master/mooncake_test/mooncake_client` 清掉目标节点/容器里
已有的旧进程；不需要时设为 0。
`unset_proxy=1` 会在目标节点清理 HTTP(S) 代理变量（默认 0，保留调用方的代理环境）；
`lock_file` 用于在控制端串行化 `start`/`stop`/`restart`，避免并发操作互相干扰。
若 `master_bin`/`client_bin` 位于节点上的 Docker 容器内，使用上面的 `host` 映射
指定每个节点的容器名。脚本在宿主机运行时，用
`host local <本机IP> <本机容器>` + `master local ...`，本地角色会通过
`docker exec` 进入容器；脚本本身在容器内运行时，用不带容器映射的 `local`，
直接在当前容器执行。
若 `client_bin` 指向 build tree，请同时设置 `ld_library_path`，并确保节点上具备
`liburing`、`libcudart` 等运行时依赖；缺失的库会由 `check` 直接列出。

> 本文是最小手动流程，不覆盖 etcd/HA、K8s、Docker 镜像构建。
> 如果需要 HA/etcd，请在此基础上增加 etcd 集群，并给 master/client 配置
> `--enable_ha=true` 和 `--etcd_endpoints`。

