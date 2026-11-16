# Mooncake 测试工具

Mooncake KVStore 的性能测试工具。它运行一个 HTTP 服务，底层由 Mooncake 的
`RealClient` 直连集群支撑，因此 put/get/exist（及其批量和零拷贝变体）可以通过任意
HTTP 压测工具（curl、wrk、JMeter）驱动。延迟数据用 t-digest 采集，提供精确的百分位。

本工具是一个完整的集群客户端：它会启动自己的 Transfer Engine，并可选择向集群贡献一段
内存 segment（`--global-segment-size`）。

## 编译

需要 CMake 3.16+、C++20 编译器，以及带完整依赖的 Mooncake 仓库。

```bash
cd <mooncake-repo-root>
cmake -S . -B build -DWITH_TE=ON -DWITH_STORE=ON -DBUILD_STORE_STABILITY_TESTS=ON
cmake --build build -j$(nproc) --target mooncake_test
```

`CLI11` and `nlohmann_json` are resolved with `find_package` first. If they are
not installed, CMake fetches CLI11 `v2.6.1` and nlohmann/json `v3.12.0` through
`FetchContent` during configuration; the repository does not vendor their
headers.

## 命令行参数

| 参数 | 默认值 | 说明 |
|--------|---------|-------------|
| `--http-host` | `0.0.0.0` | HTTP 监听地址 |
| `--http-port` | `18080` | 本工具 KV API 的 HTTP 监听端口 |
| `--http-threads` | 硬件并发数 | HTTP 服务工作线程数 |
| `--local-hostname` | `localhost` | 本节点用于集群通信的地址 |
| `--metadata-server` | `http://localhost:8080/metadata` | 元数据服务端点（URL 或 `P2PHANDSHAKE`） |
| `--global-segment-size` | `0` | 向集群贡献的 segment 大小（字节，`0` = 不贡献） |
| `--protocol` | `rdma` | 传输协议：`rdma` 或 `tcp` |
| `--rdma-devices` | （空） | RDMA 设备名，逗号分隔（空 = 自动选择） |
| `--master-server-addr` | `localhost:50051` | Master 服务地址 |
| `--local-buffer-size` | `268435456` | 本地暂存缓冲区大小（字节，256MB） |
| `--min-put-size-mb` | `1.0` | `put` / `batch_put` 的最小 `size`（MB，含边界） |
| `--max-put-size-mb` | `100.0` | `put` / `batch_put` 的最大 `size`（MB，含边界） |
| `--enable-zerocopy` | 关闭 | 使用 `put_from` / `get_into` 替代 `put` / `get` |
| `--zerocopy-recv-pool-size-mb` | `512.0` | 零拷贝接收池大小（MB） |

`--global-segment-size=0` 让本工具成为纯客户端：它可以 get/exist，put 的数据会落到其它
贡献了 segment 的集群节点（若集群中没有任何 segment，则 put 失败）。设为 `>0` 则本节点
也贡献存储，可自行承接 put。

零拷贝发送缓冲区的大小由 `--max-put-size-mb` 决定，因此它始终能覆盖任何合法的 put 值；
无需单独配置。

> **为批量 put 配置 `--local-buffer-size`（非零拷贝）：** `batch_put` 会为
> **批次中的每个 key 分配暂存空间，并持有到整个批次传输完成**，因此峰值占用为
> `batch_size × value_size`（每个并发请求）。若超过 `--local-buffer-size`，则
> **整批失败**，报错 `Failed to allocate buffer for put_batch operation`，工具返回
> `success:0`。请至少按 `max_batch × max_value × concurrency` 配置。例如
> batch=1000 × 4.2MB 需要约 4.2GB；默认 256MB 只够约 60 个 key。同时确保 pod 内存
> limit 远大于该缓冲区（它是锁定的 RDMA 内存）。

```bash
./mooncake_test \
    --http-port=18080 \
    --local-hostname="10.0.0.5" \
    --metadata-server="http://10.0.0.1:8080/metadata" \
    --master-server-addr="10.0.0.1:50051" \
    --protocol=rdma \
    --global-segment-size=536870912 \
    --http-threads=8 \
    --min-put-size-mb=1.0 --max-put-size-mb=100.0
```

## 零拷贝模式

设置 `--enable-zerocopy` 后，HTTP API 保持不变，但操作会路由到客户端的零拷贝接口：

- **发送缓冲区**：一块大的只读缓冲区，启动时预填充随机数据并注册一次。所有
  `put_from` / `batch_put_from` 共享它（安全，因为它从不被修改）。大小由
  `--max-put-size-mb` 决定。
- **接收池**：一块大缓冲区，注册一次后由 Mooncake 自己的 `ClientBufferAllocator`
  （偏移分配器）为每个 `get_into` / `batch_get_into` 子分配，与客户端管理本地 RDMA
  暂存缓冲区的方式一致。请求完成时自动归还内存区域（RAII）。大小由
  `--zerocopy-recv-pool-size-mb` 决定。
- **不回退**：若 put 值超过发送缓冲区，或接收池空间不足，请求返回 HTTP `503`——绝不
  静默回退到拷贝路径。这保证 `put_from` / `get_into` 的延迟是纯零拷贝的。
- 缓冲区分配/释放不计入计时；只对 RPC 本身计时。

响应中包含 `"zerocopy": true`。对于 `get` / `batch_get`，可选的 `"size"`（MB）提示用于
指定接收区域大小；默认值为 `--max-put-size-mb`。

如果压测时出现 `503`，说明接收池已耗尽（并发 × 对象大小超过池容量）——提高
`--zerocopy-recv-pool-size-mb` 或降低并发。

## API 参考

### 健康检查

`GET /health`

```json
{
    "ready": true,
    "status": "healthy",
    "local_hostname": "10.0.0.5",
    "metadata_server": "http://10.0.0.1:8080/metadata",
    "master_server_addr": "10.0.0.1:50051",
    "protocol": "rdma",
    "global_segment_size": 536870912
}
```

### KV 操作

`POST /api/kv`

| 字段 | 类型 | 说明 |
|-------|------|-------------|
| `operator` | string | `put`、`get`、`exist`、`batch_put`、`batch_get`、`batch_exist` |
| `key` | string | 键（批量操作时用逗号分隔） |
| `size` | string | `put` / `batch_put` 的数据大小（MB）；需在 `[min-put-size-mb, max-put-size-mb]` 范围内 |

**请求 / 响应示例：**

```json
// put  ->
{"operator":"put","key":"k1","size":"2.0"}
{"operator":"put","key":"k1","code":0,"duration_ms":2.35,"size_mb":2.0,"value_bytes":2097152,"zerocopy":false}

// get  ->
{"operator":"get","key":"k1"}
{"operator":"get","key":"k1","code":0,"size":2097152,"duration_ms":1.82,"zerocopy":false}

// exist  ->
{"operator":"exist","key":"k1"}
{"operator":"exist","key":"k1","exists":true,"code":1,"duration_ms":0.95}

// batch_put / batch_get / batch_exist use comma-separated keys ->
{"operator":"batch_put","key":"k1,k2,k3","size":"1.0"}
{"operator":"batch_put","keys":["k1","k2","k3"],"total":3,"success":3,"duration_ms":5.21,"size_mb":1.0,"value_bytes":1048576,"zerocopy":false}
```

### 数据校验功能

`get` 和 `batch_get` 操作支持可选的 `verify_data` 参数，用于验证返回数据的完整性。

**工作原理**：
- 工具启动时生成一次性随机数据缓冲区（大小为 `max-put-size-mb`）
- 所有 `put` 操作从此缓冲区的前缀提取数据（确保相同 size 的数据一致）
- `get` 时可开启校验，逐字节对比返回数据与缓冲区前 N 字节
- 适用于检测 RDMA 传输损坏、HA 故障切换后数据一致性、长时间运行的静默错误

**性能考虑**：
- 默认不校验，零性能开销
- 仅当 `verify_data=true` 时才执行校验（5MB 数据约 0.5ms）
- 校验开销通常 < 20% RPC 延迟

**单个 get 校验示例**：

```json
// 请求 - 开启校验
{"operator":"get","key":"k1","verify_data":true}

// 响应 - 校验通过
{"operator":"get","key":"k1","code":0,"size":2097152,"duration_ms":1.82,"zerocopy":false,"data_valid":true}

// 响应 - 校验失败（数据损坏）
{"operator":"get","key":"k1","code":0,"size":2097152,"duration_ms":1.82,"zerocopy":false,"data_valid":false,"mismatch_offset":1024}
```

**batch_get 校验示例**：

```json
// 请求 - 开启校验
{"operator":"batch_get","key":"k1,k2,k3","verify_data":true}

// 响应 - 全部通过
{
  "operator":"batch_get",
  "keys":["k1","k2","k3"],
  "total":3,
  "success":3,
  "duration_ms":5.2,
  "zerocopy":false,
  "data_valid":true,
  "validation_details":[
    {"key":"k1","valid":true},
    {"key":"k2","valid":true},
    {"key":"k3","valid":true}
  ]
}

// 响应 - 部分失败
{
  "operator":"batch_get",
  "keys":["k1","k2","k3"],
  "total":3,
  "success":3,
  "duration_ms":5.2,
  "zerocopy":false,
  "data_valid":false,
  "validation_details":[
    {"key":"k1","valid":true},
    {"key":"k2","valid":false,"mismatch_offset":512},
    {"key":"k3","valid":true}
  ]
}
```

**校验字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `verify_data` | boolean | 请求参数，设为 `true` 开启数据校验（默认 `false`） |
| `data_valid` | boolean | 响应字段，仅当 `verify_data=true` 且 `code=0` 时返回。`true` 表示校验通过，`false` 表示失败 |
| `mismatch_offset` | integer | 响应字段，仅当 `data_valid=false` 时返回。首个不匹配字节的偏移量（从 0 开始） |
| `validation_details` | array | batch_get 响应字段，每个 key 的详细校验结果 |

**使用限制**：
- 只能校验测试工具自己 `put` 的数据（外部写入的数据无法校验）
- pod 重启后缓冲区重新生成，旧数据无法校验
- 校验数据 size 不能超过 `max-put-size-mb`

设置 `--enable-zerocopy` 后，`put`/`batch_put` 路由到 `put_from`/`batch_put_from`，
`get`/`batch_get` 路由到 `get_into`/`batch_get_into`；响应中带有 `"zerocopy": true`。

### 性能指标

`GET /api/performance` 为每个操作标签返回一个条目，外加一个聚合的 `mix` 标签：

```json
[
  {"tag":"put","avgMs":2.28,"minMs":1.90,"maxMs":2.66,"p90Ms":2.60,"p95Ms":2.64,"p99Ms":2.66,"qps":438.15,"totalDurationMs":4.56,"totalTimeSpanMs":4.56,"totalRequests":2}
]
```

| 字段 | 说明 |
|-------|-------------|
| `tag` | `put`、`get`、`exist`、`batch_*`、`put_from`、`get_into`、`batch_put_from`、`batch_get_into` 或 `mix` |
| `avgMs` / `minMs` / `maxMs` | 平均 / 最小 / 最大 RPC 延迟（ms） |
| `p90Ms` / `p95Ms` / `p99Ms` | 百分位延迟，t-digest 估算（±0.2%~0.5%） |
| `qps` | 每秒请求数 |
| `totalDurationMs` | 所有请求耗时之和 |
| `totalTimeSpanMs` | 从首个到末个请求的时间跨度 |
| `totalRequests` | 请求数 |

只对 RPC 调用计时（不含 HTTP 解析、JSON、缓冲区管理）。`mix` 聚合所有操作类型。

`POST /api/reset` 清空所有已采集的指标。

## 架构

```
+----------------+   HTTP        +------------------+   RDMA/TCP    +-----------+
| curl / wrk /   | ------------> | HttpKVService    | -----------> | Mooncake  |
| JMeter         | POST /api/kv  | (mooncake_test / | Transfer     | cluster   |
|                |               |  RealClient)     | Engine       |           |
+----------------+               +------------------+              +-----------+
                                        | 记录
                                        v
                                 PerfCollector (t-digest)
```

## 使用示例

```bash
# 健康检查
curl http://localhost:18080/health

# put / get / batch_put
curl -X POST http://localhost:18080/api/kv -H "Content-Type: application/json" \
    -d '{"operator":"put","key":"k1","size":"2.0"}'
curl -X POST http://localhost:18080/api/kv -H "Content-Type: application/json" \
    -d '{"operator":"get","key":"k1"}'
curl -X POST http://localhost:18080/api/kv -H "Content-Type: application/json" \
    -d '{"operator":"batch_put","key":"k1,k2,k3","size":"1.0"}'

# 性能指标
curl http://localhost:18080/api/performance
curl -X POST http://localhost:18080/api/reset
```


