# 下载核心性能评估：Motrix 与 aria2

> 更新日期：2026-08-28
> 评估对象：`feat/develop-swift` 分支上的 CoolDownloadManager Swift 下载核心，以及 Motrix Turbo `v2.0.0-beta.27` 和 aria2 当前源码。
> 目标：判断 HTTP 分片下载的真实收益、系统代价，以及哪些设计值得在当前核心中借鉴。

下载设置、进度界面和大小文件策略的统一产品口径见[下载调度概念与处理流程](download-scheduling-concepts.md)；本文保留实现证据、开源项目对比和性能基准。

## 结论先行

1. **分片不是必然提速。** 当单连接已经接近链路、CDN 或服务端上限时，增加 Range 连接只会增加握手、调度、缓冲、写盘和服务端压力；单连接被限速、延迟较高或链路利用不足时，多个连接才可能近似叠加吞吐。
2. **当前核心已形成“静态小工作单元 + 动态活动 worker”的最小反馈闭环。** `DownloadService` 会探测资源，按最小分片阈值创建比连接数更多的有界 Range 工作单元，再用 1/2/4/8 风格的活动 worker 档位按完成吞吐升降并受全局连接预算约束；它仍不是 aria2 那种可以迁移已写 segment、综合 RTT/错误率/CPU/I/O 的完整调度器。
3. **本机基准显示“并发收益取决于服务端模型”，同时暴露出状态路径瓶颈。** 高速本机源中，1 连接约 89.7 MiB/s，8 连接约 67.3 MiB/s；每连接约 4 MiB/s 的受限源中，1/2/4/6 连接约为 2.87/5.90/11.80/17.89 MiB/s，8 连接又降至约 11.95 MiB/s。完整 `DownloadService` 的 256 MiB、6 分片基线约 70.9 MiB/s，而绕过状态持久化的等价 Range writer 约 385 MiB/s；后续阶段计时已去除新任务的冗余 sidecar 写入，但 checkpoint、JSON 原子替换、事件发布和 actor 往返仍需分开剖析，不能把一次前后差值全部归因于某个函数。
4. **最值得借鉴的是 aria2 的“有限工作队列 + 反馈调度 + 资源预算”，而不是把默认连接数调到 64。** Motrix 的主要价值是引擎隔离、RPC 状态同步、进程监督和恢复；实际下载算法来自 aria2。
5. **建议路线：默认单连接或低并发，满足条件后逐步升并发；预算、取消和任务轮转已经落地，下一步用压力矩阵复核边界。** 写盘合并或存储重构仍应等待 profiling 证据，不建议直接照搬 aria2 C++ 代码或把 aria2 作为 HTTP-only 的必需进程。

## 1. 范围、版本与证据

### 1.1 取样版本

| 对象 | 取样版本 | 取样方式 |
| --- | --- | --- |
| CoolDownloadManager | `12e7b0df`，`feat/develop-swift` | 当前仓库源码 |
| Motrix Turbo | `6a77297effcde5e72b1cb9f62a4b04cdf2a1db65`，`v2.0.0-beta.27` | `agalwood/Motrix` |
| aria2 | `9e7273583f83e881e3ec067b523ba88724088d2f` | `aria2/aria2` |

Motrix 和 aria2 的源码快照分别见：

- [Motrix commit](https://github.com/agalwood/Motrix/tree/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65)
- [aria2 commit](https://github.com/aria2/aria2/tree/9e7273583f83e881e3ec067b523ba88724088d2f)

### 1.2 证据强度

- **源码证据**：用于还原调用链、状态机、配置边界和资源管理。
- **本机可控 HTTP 源基准**：仓库内 `CoolDownloadBenchmark` 使用生产 `DownloadService`、流式回环 HTTP/1.1 Range 源和独立子进程运行矩阵，校验输出内容并采集吞吐、TTFB、响应 p95、CPU、RSS、FD、checkpoint、协商协议和实际服务端并发；可证明回归趋势，不能代表公网 CDN、代理或真实磁盘。
- **外部源基准**：同一工具支持 `--url`、可选 `--proxy-url`、挂载点 `--downloads-root` 和 SHA-256 校验；报告只保留协议/主机摘要，不写入完整 URL、查询参数、凭据或本机路径。HTTP/2 是否出现以 URLSession 任务指标为准，而不是由连接数推断。
- **仍未覆盖**：公网多 CDN 的重复样本、跨地域 RTT 控制、真实代理供应商、外置 HDD/网络文件系统的完整重复矩阵、系统休眠和大量任务混跑。因此“默认值”和“收益阈值”仍需要产品基准矩阵确认。

## 2. 当前 Swift 核心基线

### 2.1 下载调用链

1. `DownloadService.run` 创建 `PartFileWriter`，恢复已有记录，并建立每个任务共享的 `DownloadRateLimiter`（[DownloadService.swift:580-620](../Sources/CoolDownloadCore/DownloadService.swift#L580-L620)）。
2. HTTP 任务在需要时先发送 `Range: bytes=0-0` 探测；不支持 Range 或响应不符合约定时回退到普通 GET（[HTTPDownloader.swift:102-129](../Sources/CoolDownloadCore/HTTPDownloader.swift#L102-L129)）。
3. `downloadHTTPWithRanges` 根据已知总大小、ETag/Last-Modified 和 `Accept-Ranges` 决定是否并行（[DownloadService.swift:991-1268](../Sources/CoolDownloadCore/DownloadService.swift#L991-L1268)）。
4. `makeHTTPParts` 在连接上限和最小分片阈值内创建最多 `连接上限 × 4`、总计不超过 128 个持久化工作单元；已有文件长度映射为每个范围的已下载前缀。这样快 worker 完成后可以继续领取尚未开始的单元，但不会抢占已经写入中的 Range（[DownloadService.swift](../Sources/CoolDownloadCore/DownloadService.swift)）。
5. worker 从 `HTTPRangeWorkQueue` 领取范围，`HTTPRangeConcurrencyController` 按完成工作单元的聚合 goodput 在 1/2/4/8 风格档位升降，收益不足 10%、吞吐下降或请求失败时回退；实际请求还必须从 `HTTPRangeConnectionBudget` 获取全局 lease。每个请求使用精确 Range 和 `If-Range`，并通过 `PartFileWriter.write(_:at:)` 写入固定偏移（[HTTPRangeScheduler.swift](../Sources/CoolDownloadCore/HTTPRangeScheduler.swift)、[HTTPDownloader.swift](../Sources/CoolDownloadCore/HTTPDownloader.swift)）。

配置口径需要区分：`DownloadSchedulerConfiguration` 的构造默认值是 1 个连接，macOS 应用启动时会读取 `AppSettingsModel.threadCount` 作为单任务连接天花板；当前实现已将新安装默认值调整为 1，已有用户保存的线程数不自动重置。连接上限优先级为 **任务显式覆盖 > 主机显式覆盖 > 全局线程设置**；没有显式覆盖的自动任务会把主机学习画像作为**初始活动档位**，但画像不能永久缩小可探测上限。最终实际 Range 请求数还会被文件大小、剩余工作单元和全局 lease 预算裁剪（[Models.swift](../Sources/CoolDownloadCore/Models.swift)、[Settings.swift](../Sources/CoolDownloadCore/Settings.swift)、[AppStore.swift](../Sources/CoolDownloadManager/State/AppStore.swift)）。

### 2.2 已有优点

| 能力 | 现状 | 价值 |
| --- | --- | --- |
| 响应校验 | 校验状态码、`Content-Range`、`Content-Length`、ETag/Last-Modified，超长或短响应都会失败 | 防止错误 Range 或资源替换导致文件静默损坏 |
| 并发写入 | actor 串行化 `FileHandle`，但每次写入使用明确偏移 | 不需要下载完再拼接临时分片文件 |
| 文件准备 | 支持稀疏和密集两种准备方式；稀疏模式只扩展逻辑长度 | 适合 APFS，避免无谓的零填充 |
| 背压 | URLSession 正文通道高水位 1 MiB、低水位 512 KiB，消费者慢时暂停 data task（[NetworkPolicy.swift:48-183](../Sources/CoolDownloadCore/NetworkPolicy.swift#L48-L183)） | 避免响应数据无限堆积 |
| 表示编码 | 请求固定 `Accept-Encoding: identity`，避免 URLSession 自动解压后与 `Content-Length`/Range 字节数不一致（[HTTPDownloader.swift](../Sources/CoolDownloadCore/HTTPDownloader.swift)） | 保证保存的是服务器原始下载表示；压缩传输收益需由 CDN/代理另行 A/B |
| 限速 | 每个任务共享一个本地 `DownloadRateLimiter`，所有 HTTP/HLS 任务再共同继承一个全局 limiter（[RateLimiter.swift](../Sources/CoolDownloadCore/RateLimiter.swift)） | 分片数变化不会复制限速额度；全局值是所有活动任务的聚合硬上限 |
| 恢复安全 | 启动时把没有活跃 Task 的 `downloading/preparing/retrying` 标记为 paused，并保留 part 文件（[DownloadService.swift:42-65](../Sources/CoolDownloadCore/DownloadService.swift#L42-L65)） | 进程崩溃后不会伪装成仍在下载 |

### 2.3 已实施的 P0 与 P1 最小闭环

当前实现已加入最小分片阈值、全局 Range 连接预算、有限 worker 队列、粗粒度慢连接再平衡、活动 worker 自适应档位、带 TTL 的主机画像、全局聚合限速、进程级响应缓冲预算、独立重试预算、FD reservation 和任务级轮转公平，以及分离的进度事件/checkpoint 节奏。已有非空 `parts` 不会自动重切分；新任务的小文件、禁用 HTTP 分片和单连接上限任务走普通 GET。关闭 HTTP 分片只影响尚未建立分片的新任务，已有分片任务仍保留 Range 恢复路径。以下风险表描述的是完整资源预算和进一步 profiling 前仍存在的边界。

### 2.4 当前主要瓶颈和风险

| 位置 | 观察 | 影响 |
| --- | --- | --- |
| [HTTPRangeScheduler.swift](../Sources/CoolDownloadCore/HTTPRangeScheduler.swift) | 已按工作单元完成 goodput、请求耗时和可恢复失败升降活动 worker；永久性 HTTP 4xx 不再触发并发降档。基准报告已采集响应 p95、失败响应和 CPU/I/O 资源，但尚未把这些指标全部纳入在线反馈 | 当前是可回退的最小控制器，不是完整的系统负载自适应 |
| [DownloadService.swift](../Sources/CoolDownloadCore/DownloadService.swift) | 快 worker 可继续领取额外未开始工作单元；已经进行中的慢 Range 不会被切分或迁移，单个 Range 失败仍结束本次尝试 | 避免重复写和状态竞态，但慢尾部和局部重试仍有优化空间 |
| [HostPerformance.swift](../Sources/CoolDownloadCore/HostPerformance.swift) | 画像只保存协议、主机、端口、连接档位、聚合吞吐和成功/失败计数，默认 7 天 TTL、最多 256 条 | 已守住 URL/凭据隐私边界；网络环境变化只能靠 TTL 重新学习 |
| [DownloadService.swift:1125-1195](../Sources/CoolDownloadCore/DownloadService.swift#L1125-L1195) | 网络进度、250ms UI 事件和 2s checkpoint 已分离 | 仍需用 profiling 确认 JSON/fsync 是否为首要瓶颈 |
| [Storage.swift:130-180](../Sources/CoolDownloadCore/Storage.swift#L130-L180)、[Storage.swift:205-231](../Sources/CoolDownloadCore/Storage.swift#L205-L231) | 每次保存都编码记录、写入并同步后原子替换；现代记录的 `parts` 已内嵌，只有旧格式或已有 sidecar 才继续写兼容文件 | 仍需关注记录 JSON 的 fsync、临时文件和全记录编码；兼容 sidecar 不再给新任务增加固定写放大 |
| [NetworkPolicy.swift](../Sources/CoolDownloadCore/NetworkPolicy.swift)、[HTTPRangeScheduler.swift](../Sources/CoolDownloadCore/HTTPRangeScheduler.swift) | 每请求正文通道约 1 MiB 高水位，并由进程级 16 MiB 响应缓冲 lease、FD reservation 约束；报告可记录 URLSession 协议和连接复用 | 等待预算的请求不创建 socket；公网 HTTP/1.1/HTTP/2 已可观测，代理场景仍需重复矩阵 |
| [NetworkPolicy.swift](../Sources/CoolDownloadCore/NetworkPolicy.swift)、[HTTPDownloader.swift](../Sources/CoolDownloadCore/HTTPDownloader.swift) | 已收到 HTTP 响应但 metrics 缺失时，delegate 最多保留 completed context 5 秒；tracker 对晚到协议指标观察 1 秒后解除观察 | 避免 metrics 回调永久缺失造成 context 泄漏，也避免 body 先结束时丢失协议/连接复用事件；超出窗口的指标按 best-effort 丢弃 |
| [DownloadService.swift](../Sources/CoolDownloadCore/DownloadService.swift) | 重试尝试独立受全局槽位约束，FD reservation 覆盖 part 文件和 HTTP 请求；等待和退避不占槽位 | 避免多个任务同时故障时形成重试风暴；仍需在大量任务压力下复核队列延迟 |
| [NetworkPolicy.swift:422-441](../Sources/CoolDownloadCore/NetworkPolicy.swift#L422-L441) | URLSession 同主机连接配置至少为 64 | 这是上限配置，不等于实际建立 64 条连接，也不是任务级连接预算 |
| [DownloadService.swift](../Sources/CoolDownloadCore/DownloadService.swift) | `dynamicPartCreation` 仍是兼容旧配置键的“是否启用 HTTP 分片”开关；范围布局保持静态，活动 worker 会运行时反馈升降；运行时降低 FD 预算会暂停最新的超额活动任务 | 设置名容易让人误以为分片边界本身会动态重切分 |

## 3. HTTP 分片是否提速

### 3.1 什么时候能提速

把单连接可用吞吐记为 `C`，链路、服务端或客户端的总上限记为 `B`，理想情况下 `n` 个独立连接的有效吞吐接近：

```text
throughput(n) ≈ min(B, n × C) - connection_and_scheduling_overhead
```

因此分片有收益的典型条件是：

- 服务端对单 TCP 连接或单请求有带宽上限；
- 单连接受较高 RTT、拥塞窗口或代理策略限制，无法填满链路；
- 服务端正确支持 Range，并允许多个并发请求；
- 文件足够大，分片工作量大于连接建立和调度成本；
- 客户端写盘、校验和内存带宽不是新的瓶颈。

### 3.2 什么时候不提速甚至降速

- 单连接已经接近本地出口、Wi-Fi、VPN、CDN 或服务端总上限；
- CDN 对同一 IP、同一 URL 或同一用户有总并发/总带宽限制；
- 服务端对每个 Range 都重新做鉴权、解密或回源；
- HTTP/2 已经把请求复用在少量连接上，增加逻辑分片不一定增加物理 TCP 连接；
- 文件很小，探测、TLS、请求头和任务调度时间占主要比例；
- 下载路径被随机写、频繁 fsync、JSON 编码或 UI 事件处理限制；
- 连接数超过最佳点，引发丢包、队头阻塞、429/503、重试或代理排队。

### 3.3 系统开销

| 资源 | 随连接/分片增加的成本 | 需要控制的指标 |
| --- | --- | --- |
| CPU | TLS、HTTP 解析、数据复制、Range 调度、校验、状态编码 | user/system CPU、每 MiB CPU 时间 |
| 内存 | 每个请求的 socket、URLSession 状态、响应缓冲和任务对象；当前每个正文通道高水位约 1 MiB | 峰值 RSS、应用自有缓冲、悬挂任务数 |
| 文件描述符 | 可能一连接一 socket，HTTP/2/连接池会改变实际数量；状态文件也会占用短时 FD | `RLIMIT_NOFILE`、活跃 socket 数、打开文件失败 |
| 磁盘 | 多范围乱序写、稀疏文件 extent、原子替换、checkpoint fsync；密集分配还会预写零 | 内核按进程记账的写入增量、`synchronize()` 次数/耗时、物理占用、I/O wait |
| 网络 | 更多握手、请求头、ACK、重试和服务端并发压力 | 请求数、重试率、RTT、429/5xx、实际连接数 |

## 4. 当前本机基准

### 4.1 条件与复现方式

- 仓库内 [Benchmarks/README.md](../Benchmarks/README.md) 提供 `CoolDownloadBenchmark`：默认是本机 `127.0.0.1` 流式 HTTP/1.1 Range 源，也可切换外部 HTTP(S) URL；生产 `DownloadService`、每次运行独立子进程、确定性内容/长度校验和结构化 JSON 报告（schema version 4）。报告额外记录记录文件和 parts sidecar 的 JSON 编码、写入、同步与原子替换阶段耗时，便于决定是否需要写缓存或存储重构。
- 高速源用于观察并发上限；`--per-connection-mibps` 可模拟每条连接限速，`--tasks` 和 `--global-connections` 可验证多任务共享预算，`--max-open-fds` 可压低 FD 准入边界，`--fail-first-data-requests`、`--retry-attempts` 和 `--retry-delay-ms` 可复现有限重试压力。
- 下表数值来自 2026-08-27 的临时 `Bench`/`DirectBench` probe，而不是当前正式 benchmark 的新基线。它们用于解释优化方向，不能作为当前提交或公网性能承诺。
- 2026-08-28 已用 `CoolDownloadBenchmark` 完成多轮固定机器的单任务/多任务可控源矩阵；此前基线 JSON 保存在 `/tmp/cooldm-benchmark-highspeed.json`、`/tmp/cooldm-benchmark-limited-concurrent-formal.json` 和 `/tmp/cooldm-benchmark-multitask-concurrent-global16.json`，本轮回归保存在 `/tmp/cooldm-benchmark-priority-success.json`、`/tmp/cooldm-benchmark-priority-failure.json` 和 `/tmp/cooldm-benchmark-priority-1m.json`。这些结果仍只代表本机 HTTP/1.1 夹具，不足以调整 16 MiB 或全局 16 lease 默认值。

历史 probe 和原始输出未纳入仓库，因此当前表格只能作为方向性证据；后续回归应使用 `CoolDownloadBenchmark` 的 schema-versioned JSON，并固定硬件、电源模式、系统版本、负载、重复次数和冷热缓存条件。

本轮基准夹具同时修正为并发发送队列；此前串行发送队列会把“每连接限速”错误地变成全局限速，修正前的受限源数字不作为结论。

### 4.2 结果

**高速源：并发增加没有收益，且 RSS 上升。**

| 逻辑连接数 | 吞吐 |
| ---: | ---: |
| 1 | 约 89.7 MiB/s |
| 2 | 约 71.5 MiB/s |
| 4 | 约 71.5 MiB/s |
| 6 | 约 66.2 MiB/s |
| 8 | 约 67.3 MiB/s |

观测到 RSS 约从 62 MB 增加到 99 MB。这个结果支持“链路/服务端已是主要上限时，分片只增加开销”的判断。

**每连接约 4 MiB/s 的受限源：并发先近似叠加，超过最佳点后回落。**

| 逻辑连接数 | 吞吐 |
| ---: | ---: |
| 1 | 约 2.87 MiB/s |
| 2 | 约 5.90 MiB/s |
| 4 | 约 11.80 MiB/s |
| 6 | 约 17.89 MiB/s |
| 8 | 约 11.95 MiB/s |

6 连接相对 1 连接约 6.2 倍；8 连接回落到约 6 连接的 67%。这说明“更多连接”不是单调优化，必须允许探测后回退。

**状态路径对比：**

| 路径 | 负载 | 吞吐 |
| --- | --- | ---: |
| 完整 `DownloadService` | 256 MiB，6 分片，含记录保存、分片进度和事件 | 约 70.9 MiB/s |
| 等价 Range writer | 256 MiB，6 个 Range，绕过状态持久化和进度事件 | 约 385 MiB/s |

**2026-08-28 `CoolDownloadBenchmark` 回归：**

| 场景 | 连接上限 | goodput（实测） | 观察 |
| --- | ---: | ---: | --- |
| 高速本机源，单任务，256 MiB | 1 | 约 1,819-1,926 MiB/s | 普通 GET 最高 |
| 高速本机源，单任务，256 MiB | 2 | 约 1,793-1,797 MiB/s | 已低于单连接 |
| 高速本机源，单任务，256 MiB | 4/8/16 | 约 1,618-1,696 MiB/s | 更多 Range 没有收益，checkpoint 约 31-34 ms |
| 每连接 20 MiB/s，单任务，256 MiB | 1/2/4/8/16 | 约 15.0/24.0/39.9/48.6/48.2 MiB/s | 8 后平台化，16 未继续增加 |
| 每连接 20 MiB/s，多任务 2，128 MiB/任务 | 4/8/16 | 约 82.5/99.4/99.5 MiB/s | 全局 16 lease 未成为瓶颈，峰值 FD 约 25-43 |

所有 measured runs `verified=true`；服务端观测并发和请求数随 Range 增加，说明矩阵实际打到了并发路径。多任务全局上限压到 4 的补充运行总吞吐约 12.2 MiB/s，证明预算会收紧总吞吐；当前实现已对等待中的 Range、重试槽位和 FD reservation 按任务轮转。

2026-08-28 新增失败压力选项后，4 个任务、FD 预算 4、首批 4 个数据请求返回 503 的本机运行仍全部 `verified=true`：1/2/4 连接 goodput 约 9.21/11.28/11.46 MiB/s，重试数和失败响应数均为 4，服务端失败计数为 4。该结果只证明预算和释放路径可运行，不代表公网错误率或尾延迟。

同一夹具的长压扩展为 8 个任务、每任务 16 MiB、FD 预算 4、首批 4 个数据请求返回 503，1/2/4 连接运行约 14.092/14.145/12.275 秒，goodput 约 9.08/9.05/10.43 MiB/s，响应耗时 p95 约 3,543/433/212 ms，峰值 OS FD 约 15/15/17，全部 `verified=true`。OS FD 高于 reservation 是 URLSession 和测试进程本身的句柄；reservation 只负责限制核心主动持有的 part/request 槽位。

**checkpoint 原子替换 A/B（2026-08-28，同一机器、64 MiB、最小分片 16 MiB、各 1 次）**：将记录和 sidecar 的同目录临时文件替换从 `FileManager.replaceItemAt` 改为 POSIX `rename` 后，阶段计时出现下降：

| 连接 | checkpoint 总耗时（改前/改后） | 记录替换（改前/改后） | sidecar 替换（改前/改后） | goodput（改前/改后） |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 6.16/2.52 ms | 4.12/0.55 ms | 不适用/不适用 | 1,250/1,755 MiB/s |
| 4 | 12.47/7.22 ms | 5.07/0.97 ms | 1.81/0.55 ms | 1,275/1,308 MiB/s |

这是同负载隔离子进程的一次前后观测，不足以给出稳定收益承诺；它支持保留 `rename` 原子替换和分阶段指标，并继续用多次重复、外置卷和网络文件系统矩阵复核。尚未因此加入写缓存或改变 16 MiB/16 lease 默认值。

这不是严格的火焰图或单变量实验，不能把差值全部归因于一个函数；但它足以把“先剖析状态/持久化路径”排在“继续增加连接数”之前。

另一个重要观察是：URLSession 配置了 8 个逻辑并发时，实际同主机并发约为 6。连接池、协议版本和系统调度会改变物理连接数，不能把 `httpMaximumConnectionsPerHost` 或分片数直接当成真实 socket 数。

### 4.3 公网源与协议观测

使用 `--url https://proof.ovh.net/files/100Mb.dat --size-mib 100 --connections 1,2,4 --minimum-part-mib 16` 在同一台机器各运行一次，结果均 `verified=true`：1/2/4 连接 goodput 约为 **1.12/1.65/1.43 MiB/s**；2 连接的协商协议指标为 **7 个请求均 `http/1.1`**，其中 5 个复用连接。该单次样本表明公网端点在本次网络路径上 2 连接优于 1 连接，但 4 连接回落，不能据此调整默认值。

为验证 HTTP/2 协商和压缩表示，使用 `https://raw.githubusercontent.com/aria2/aria2/master/README.rst`（22,434 字节，SHA-256 校验）运行外部模式，结果 `verified=true`，协议指标为 **`h2`**。该响应通过 gzip 提供压缩 `Content-Length`，固定 `Accept-Encoding: identity` 后下载器按解压前的实际文件长度完成校验；此前未固定该请求头会出现“响应声明 7,805 字节但正文 22,434 字节”的长度错误。

以上公网结果只记录为当前网络环境的可重复起点：需要同一端点多次重复、不同 CDN/区域、代理开关和挂载点矩阵后，才能把协议或存储差异纳入自动升档条件。

本轮针对同一 OVH 公网端点（`10Mb.dat`，10 MiB、每档 3 次、warmup 1）复测，1/2/4 连接平均 goodput 约为 **1.12/1.44/1.60 MiB/s**，对应请求均 `verified=true`；2/4 连接实际各发出 5 个 Range 数据请求并观察到 4 个复用连接，4 连接的 checkpoint 平均约 27.8 ms，高于 1 连接约 12.8 ms。该样本支持“满足单连接受限时分片有收益，但状态成本同步上升”的判断，不足以调整默认并发。原始报告为 `/tmp/cooldm-benchmark-priority-ovh10m.json`。

同一轮对 GitHub Raw 的小文件外部模式（`README.rst`，每档 3 次）观测到协议指标稳定为 **`h2`**；1 连接直接普通 GET 平均约 0.047 MiB/s，2/4 连接因探测后仍按小文件单连接下载，平均约 0.032 MiB/s。它用于验证 HTTP/2 指标和 `Accept-Encoding: identity` 的长度一致性，不用于比较大文件吞吐。原始报告为 `/tmp/cooldm-benchmark-priority-h2.json`。

### 4.4 存储挂载点初步观测

在同一台机器、同一 `127.0.0.1` 高速夹具、64 MiB 文件、1/4 连接、各 2 次测量下，系统 APFS（临时目录）与外置 APFS（`/Volumes/XG_SSD`）均完成内容校验：

| 目标 | 连接 | goodput（两次） | checkpoint 总耗时（两次） | 峰值 RSS 范围 |
| --- | ---: | ---: | ---: | ---: |
| 系统 APFS | 1 | 1,623/1,342 MiB/s | 5.2/4.8 ms | 59/101 MiB |
| 系统 APFS | 4 | 1,268/1,274 MiB/s | 12.6/13.4 ms | 62/72 MiB |
| 外置 APFS | 1 | 645/584 MiB/s | 5.4/6.7 ms | 113/117 MiB |
| 外置 APFS | 4 | 484/468 MiB/s | 18.6/18.2 ms | 72/89 MiB |

这组结果显示外置卷在本机夹具上明显慢于系统卷，且 4 连接的 checkpoint 成本高于 1 连接；但样本少、缓存和卷状态未完全控制，不能把差异归因于 `PartFileWriter` 或 APFS 本身。当前证据支持继续保留有界 checkpoint 和低并发默认，不支持直接加入写缓存。OrbStack 的 NFS 挂载在本机对该测试用户不可写，未将权限失败伪装成网络文件系统性能结果；真正的 NAS/NFS A/B 需要可写的测试挂载点。

**优先级实施后的重复观测（2026-08-28）**：系统 APFS 高速夹具 64 MiB、单任务、每档 3 次（warmup 1）中，1/2/4/8/16 连接平均 goodput 约为 **1,582/1,260/1,150/1,125/1,142 MiB/s**；1 连接最高，16 连接比 1 连接低约 28%，所有输出均 `verified=true`。失败压力夹具（2 任务、全局 Range 预算 2、FD 预算 4、前 2 个数据请求返回 503）中，1/2/4 连接平均约 **741/623/581 MiB/s**，每档均观察到 2 个失败响应和 2 次重试且最终校验通过；4 连接 checkpoint 平均约 17.7 ms，高于 1 连接约 5.7 ms。

外置 USB APFS SSD（`/Volumes/XG_SSD`）同负载每档 3 次时，1 连接平均约 **640 MiB/s**、checkpoint 约 **3.8 ms**，4 连接平均约 **472 MiB/s**、checkpoint 约 **13.2 ms**；峰值 RSS 分别约 108-127 MiB 与 95-100 MiB。该结果支持保留低并发和有界 checkpoint，不支持直接引入写缓存。`/Volumes/storage`（USB HDD）和 OrbStack NFS 在当前用户下不可写，未纳入伪造的“成功”样本。

**兼容 sidecar 去除后的复测（2026-08-28）**：现代 Codable 记录将 `parts` 内嵌后，新任务不再同步第二份 sidecar。系统 APFS 高速夹具 64 MiB、单任务、每档 3 次（warmup 1）中，1/2/4/8/16 连接平均 goodput 约为 **1,604/1,126/1,244/1,201/1,170 MiB/s**，checkpoint 平均约 **2.6/5.0/5.8/5.0/4.9 ms**；对应 sidecar 阶段均为 0，所有输出均 `verified=true`。与同参数的前一轮观测相比，Range 档位 checkpoint 总耗时下降约 20%-35%，但 goodput 仍受本机高速源和调度噪声影响，不能把全部差值归因于 sidecar 优化。

同一外置 USB APFS SSD、1/4 连接的平均 goodput 约为 **687/522 MiB/s**，checkpoint 约 **3.8/12.3 ms**，sidecar 阶段同样为 0，全部校验通过。该结果支持保留“现代记录内嵌 parts、旧格式/已有 sidecar 继续写回”的兼容策略；记录 JSON 编码、`synchronize()` 和真实 HDD/NFS 的物理 I/O 仍需独立 profiling，当前没有证据引入 WAL、任务级写缓存或相邻写合并。

## 5. Motrix 的实现原理与可借鉴点

### 5.1 Motrix 的边界

Motrix Turbo 的 README 明确把界面、应用内核、engine adapter 和 aria2 分成四层；桌面端和 headless server 共用 core，下载引擎是随应用分发的 Motrix aria2 fork（[README.zh-CN.md:224-250](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/README.zh-CN.md#L224-L250)）。

因此：

- **Motrix 负责**任务模型、设置、SQLite 元数据、JSON-RPC/IPC、引擎启动和恢复、UI 轮询与事件；
- **aria2 负责**HTTP/FTP/SFTP/BT/Metalink 协议、Range/piece 调度、连接、缓存、校验和写盘；
- Motrix 的轻量模式主要释放隐藏窗口的 renderer 进程，不能直接证明 aria2 下载核心的网络性能更高。

### 5.2 性能配置不是单一“线程数”

Motrix 用性能 profile 联动四个参数：`maxConnectionPerServer`、`split`、`minSplitSize`、`diskCache`（[engine-performance-profiles.ts:1-73](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/shared/constants/engine-performance-profiles.ts#L1-L73)）。当前 beta 的配置值为：

| Profile | 每服务器连接 | split | 最小分片 | 磁盘缓存 |
| --- | ---: | ---: | ---: | ---: |
| auto | 64 | 16 | 4 MiB | 32 MiB |
| balanced | 16 | 16 | 10 MiB | 32 MiB |
| high | 32 | 32 | 4 MiB | 64 MiB |
| maximum | 64 | 64 | 1 MiB | 64 MiB |

这些值是 Motrix 产品 profile，不应直接复制为 CoolDM 默认值。值得借鉴的是**把连接数、最小分片和缓存作为一组策略**，并允许设置校验和内核能力报告限制上限。

### 5.3 磁盘感知调优

`aria2-tuning.ts` 按文件系统、磁盘类型和文件大小选择策略：网络文件系统降低到约 2 个 split、20 MiB 最小分片和 16 MiB cache；HDD 使用约 8 个 split 和 20 MiB 最小分片；SSD 再按小/中/大/超大文件提高并发（[aria2-tuning.ts:49-213](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/core/engine/aria2/aria2-tuning.ts#L49-L213)）。

这比向所有用户暴露“线程数 1-64”更有价值。CoolDM 的 macOS/APFS 优先路线可以先实现：网络文件系统保护、HDD 低并发、APFS SSD 按大小分档，并将推荐值作为可解释的建议而不是强制覆盖。

### 5.4 引擎隔离、监督和状态同步

- `Aria2ConfigBuilder` 将 conf、引擎绑定参数、用户调优参数和产品不变量分层，最后追加 `--max-connection-per-server`、`--split`、`--min-split-size`、`--disk-cache`、session/save 参数（[aria2-config-builder.ts:112-225](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/core/engine/aria2/aria2-config-builder.ts#L112-L225)）。
- `Aria2ProcessManager` 记录 PID、二进制和参数指纹，保留有界 stderr 尾部，支持优雅停止和超时强杀（[aria2-process-manager.ts:57-186](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/core/engine/aria2/aria2-process-manager.ts#L57-L186)）。
- `PollingScheduler` 活跃时每 1 秒、空闲时每 10 秒轮询；事件只作为提示，最终仍用 `getGlobalStat/tellActive/tellWaiting` 的 multicall 做权威同步（[polling-scheduler.ts:11-228](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/core/engine/aria2/polling-scheduler.ts#L11-L228)）。
- `SessionManager.restore` 以 aria2 当前 GID 为一侧、Motrix SQLite 元数据为另一侧做恢复和去重，避免 UI 数据库与引擎状态各自“认为自己是权威”（[session-manager.ts:398-608](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/core/session/session-manager.ts#L398-L608)）。
- SQLite 使用 WAL、`synchronous=NORMAL`、预编译语句和行签名跳过未改变任务的写入（[motrix-database.ts:191-246](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/core/session/motrix-database.ts#L191-L246)、[motrix-database.ts:479-551](https://github.com/agalwood/Motrix/blob/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65/src/core/session/motrix-database.ts#L479-L551)）。

对 CoolDM 最直接的借鉴是：**下载循环只维护内存态，耐久 checkpoint 合并/节流；UI 更新和磁盘持久化不应绑定每个网络 chunk。**

## 6. aria2 的核心实现原理

### 6.1 四个参数的职责不同

aria2 文档区分了三层并发：

- `--max-concurrent-downloads`：同时下载多少个任务；
- `--split`：一个任务最多使用多少个逻辑连接；
- `--max-connection-per-server`：一个任务到同一服务器的连接上限；
- `--min-split-size`：小于 `2 × SIZE` 的剩余范围不再切分（[aria2c.rst:54-77](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/doc/manual-src/en/aria2c.rst#L54-L77)、[aria2c.rst:183-213](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/doc/manual-src/en/aria2c.rst#L183-L213)、[aria2c.rst:317-325](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/doc/manual-src/en/aria2c.rst#L317-L325)）。

`--stream-piece-selector=default` 的说明还明确指出，默认选择策略会减少新建连接，因为建连本身昂贵；`inorder`、`random`、`geom` 是不同的内容优先策略（[aria2c.rst:335-360](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/doc/manual-src/en/aria2c.rst#L335-L360)）。

### 6.2 SegmentMan/PieceStorage：动态领取工作单元

aria2 不把整个文件永久绑定给 N 个 worker：

1. `SegmentMan::getSegment(cuid, minSplitSize)` 从 `PieceStorage` 领取未完成 piece；
2. 一个命令完成当前 segment 后，再领取下一个 segment；
3. 失败或取消会把 segment 归还，并记忆已写长度；
4. `getCleanSegmentIfOwnerIsIdle` 只在原 owner 空闲且尚未写入时允许接管；
5. `DownloadCommand::prepareForNextSegment` 在完成后继续领取下一个 piece，而不是一次性创建所有连接。

对应源码：

- [SegmentMan.h:73-176](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/SegmentMan.h#L73-L176)
- [SegmentMan.cc:134-220](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/SegmentMan.cc#L134-L220)
- [SegmentMan.cc:245-347](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/SegmentMan.cc#L245-L347)
- [DownloadCommand.cc:317-379](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/DownloadCommand.cc#L317-L379)

这解决了静态均分的两个问题：慢连接不会永久占住整个大范围，连接完成后可以继续消费剩余工作；但要注意，已经写入一部分的连接不能被粗暴“抢走”，否则会产生重复写或 Range 状态不一致。

### 6.3 ServerStat 和自适应并发

aria2 记录主机/协议维度的总速度、单连接平均速度、多连接平均速度和错误状态（[ServerStat.h:47-135](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/ServerStat.h#L47-L135)）。`RequestGroupMan` 可以按最近吞吐选择 URI，并在启用 `optimize-concurrent-downloads` 时根据观测速度动态计算任务并发；当前实现至少等待约 5 秒观察窗口，再用参考速度和当前速度调整，并把结果限制在配置范围内（[RequestGroupMan.cc:1063-1114](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/RequestGroupMan.cc#L1063-L1114)）。

CoolDM 不需要照搬 aria2 的公式，但应保留三个原则：

- 先建立单连接基线，再试探 2、4、8；
- 只有边际吞吐持续增加且错误/延迟没有恶化才升档；
- 发现吞吐下降、429/5xx 或超时增多时立即降档，并给主机结果设置 TTL，避免一次异常永久污染配置。

### 6.4 有界磁盘缓存、分配和校验

- `WrDiskCache` 以任务/ piece 写缓存为单位，维护总字节上限，超限时刷出最旧条目（[WrDiskCache.h:48-75](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/WrDiskCache.h#L48-L75)、[WrDiskCache.cc:45-127](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/WrDiskCache.cc#L45-L127)）。
- piece 完成时可做 hash 校验；校验失败只重试对应 piece，而不是重下整个文件（[DownloadCommand.cc:237-274](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/DownloadCommand.cc#L237-L274)）。
- session 保存写到临时文件，关闭后再 rename；自动保存由时间命令触发，而不是每个网络 chunk 触发（[SessionSerializer.cc:64-95](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/SessionSerializer.cc#L64-L95)、[AutoSaveCommand.cc:41-61](https://github.com/aria2/aria2/blob/9e7273583f83e881e3ec067b523ba88724088d2f/src/AutoSaveCommand.cc#L41-L61)）。

这些机制的共同点是**有界**：缓存有上限、并发有上限、session 有明确保存周期、piece 状态可以局部恢复。

## 7. 对当前核心的逐项对比

| 维度 | 当前 Swift | aria2/Motrix | 评估 |
| --- | --- | --- | --- |
| 引擎边界 | HTTP/HLS 直接在 Swift actor 内 | Motrix core 与独立 aria2 进程通过 adapter/RPC 隔离 | HTTP-only 继续原生更轻；需要 BT/Metalink/远程控制时再考虑引擎后端 |
| Range 正确性 | 校验较完整，偏移写入 | piece/segment 状态、重试和校验成熟 | 保留当前校验，借鉴 piece 状态机 |
| 分片布局 | 最小阈值下创建最多 `连接上限 × 4`、总计不超过 128 个静态工作单元 | `min-split-size` + PieceStorage 动态领取 | 已支持快 worker 多领未开始工作；尚不迁移部分写入的 Range |
| in-flight 数量 | 1/2/4/8 风格活动 worker + 全局 Range lease | 命令按需领取，受全局/任务预算约束 | 已按 goodput/失败回退；尚未综合 RTT、CPU、I/O 和错误率窗口 |
| 慢连接 | 通过额外未开始工作单元做粗粒度再平衡 | 空闲、未写入 segment 可被接管；完成后继续领新 segment | 已覆盖安全的第一步；单个进行中慢尾部仍不会被抢占 |
| 主机经验 | 协议/主机/端口级画像，7 天 TTL、最多 256 条，不保存 URL 路径和凭据 | ServerStat 区分单/多连接速度并支持反馈选择 | 已用于自动任务起始档位，但不再充当永久硬上限 |
| 限速 | 任务/主机本地 limiter 嵌套共享全局 limiter | aria2 有全局和单任务限速 | 全局值是 HTTP/HLS 活动任务的聚合硬上限；本地 `nil/0` 不能绕过它 |
| 缓冲 | URLSession 通道每请求约 1 MiB 高水位，进程级响应预算 16 MiB | aria2 有界写磁盘缓存 | 网络背压和总响应预算已落地；任务级写缓存仍待 profiling |
| 重试/FD | 重试槽位默认 2；part 文件与 HTTP 请求共享默认 128 个 FD reservation，均按任务轮转 | aria2 对连接、缓存和任务状态有多级资源控制 | 已防止重试风暴和请求/文件句柄无界增长；真实 OS FD 与代理场景仍需复核 |
| 持久化 | JSON 原子替换；现代记录内嵌 `parts`，兼容 sidecar 仅对旧格式/已有文件维护；HTTP 进度约 2 s checkpoint、250 ms UI 事件 | SQLite WAL/预编译/行变更跳过 + aria2 session | 已去除新任务的固定 sidecar 写放大；记录 JSON/fsync 仍需 profiling，不能据此引入更重存储 |
| 文件分配 | APFS 默认可稀疏，支持 dense | none/prealloc/falloc 等按环境选择 | 借鉴环境感知，不直接复制 Linux 策略 |
| UI 状态 | AsyncStream 事件 | 1 秒活跃、10 秒空闲轮询，通知只作提示 | 事件应可合并，不能让 UI 反压下载循环 |
| 进程恢复 | 同一进程重启后标记 paused | 引擎独立、PID 监督、GID 与数据库双向恢复 | 只在引入外部引擎时借鉴完整模型 |

## 8. 建议实施路线

### P0：先修正收益/代价模型（已完成）

1. **把 `dynamicPartCreation` 改成真实语义。** 当前保留旧设置键以兼容已有配置，UI 已改为“启用 HTTP 分片”；实际语义仍是启用静态 Range 分片，后续可在配置迁移时改成更直观的内部名称。
2. **加入最小分片阈值和连接预算。** 当前默认最小分片为 16 MiB、全局 Range 连接预算为 16；逻辑为：

   ```text
   configured ceiling = task override
                     ?? host override
                     ?? global per-task setting
   initial active stage = learned host profile (automatic jobs only)
   worker count = min(configured ceiling,
                      pending work units,
                      global Range lease budget)
   ```

   新任务的连接上限为 1 时直接走普通 GET；资源大小未知、不支持 Range、经过不透明代理或响应不稳定时不要强行分片。若新任务上限大于 1，自动任务可以从画像档位开始并继续向上试探；已有 `parts` 的任务即使关闭开关也保留 Range 恢复路径。当前仍需通过真实基准确认 16 MiB 是否适合公网 CDN。
3. **改为有限工作队列。** 当前只创建有限 worker，工作单元包含范围和已下载偏移，实际 Range 请求受全局 lease 约束；新布局会创建额外未开始工作单元，快 worker 可持续领取以缩小慢连接造成的静态尾部。失败会释放 lease，任务级重试重新从持久化进度构建队列。
4. **分离三类状态。** HTTP 普通 GET/Range 路径的网络进度只更新内存，UI 事件约 250 ms 合并，checkpoint 约 2 秒、每新增约 64 MiB 或重要状态转换时保存；暂停、退出、分片完成、失败和完成仍强制刷盘。初始 8 MiB 阈值在隔离进程的高速回环基准中让 checkpoint 占墙钟时间约 29%-41%，因此先提高到 64 MiB；HLS 仍按分片完成回调保存，未纳入这次高频 HTTP 节流。
5. **先测量再改写盘实现（阶段采集与首轮重复 A/B 已落地）。** 可选的 `DownloadMetricsSink` 已记录任务开始/结束资源快照、HTTP 普通 GET/Range/探测请求、收到响应头的首字节时间、重试、checkpoint 和事件发布耗时；`DownloadStore.save` 同时记录 JSON/sidecar 编码字节、逻辑写入字节、内核按进程记账的写入字节、`synchronize()` 次数和完整 checkpoint 耗时，并在启用指标时分别记录记录文件和兼容 sidecar 的编码、写入、同步、原子替换阶段耗时。现代 Codable 记录的 `parts` 已内嵌，新任务不会重复创建 sidecar；旧格式或已有 sidecar 仍保持写回。这个内核计数不是设备物理落盘量，也不能证明 fsync 已完成持久化。默认 sink 为 no-op；只有采样运行才承担额外开销。当前结果支持去除新任务的冗余 sidecar 写入，但仍不足以证明需要单文件 WAL/SQLite 或任务级写缓存。

### P1：让并发具有反馈能力（最小闭环已完成）

1. **慢连接再平衡（已完成第一阶段）。** 新任务按最多 `连接上限 × 4` 创建有界工作单元，快 worker 完成后继续领取尚未开始的单元；对已写入部分不做中途迁移，避免重复写和恢复状态竞态。
2. **自适应并发（已完成最小控制器）。** 自动任务从 1 或主机画像档位开始，按完成工作单元的聚合 goodput 试探 2/4/8...，但只在任务/主机/全局配置的连接上限内运行；候选档位至少提升 10% 才保留，并要求阶段最大请求耗时不超过稳定阶段的 2 倍。吞吐下降、耗时尾部恶化或可恢复失败时回退并冷却；永久性 HTTP 4xx 只让任务失败，不污染并发阶段。显式任务/主机线程设置优先作为硬上限和起始值。这里的耗时是取得 Range lease 后的请求占用时间，不等同于协议 RTT；p95 RTT、错误率窗口、CPU/I/O 压力反馈仍待稳定 profiling，10% 和 2 倍仍是实验门槛而非公网保证。
3. **主机画像（已完成最小存储）。** `HostPerformanceStore` 保存协议、规范化主机、端口、稳定连接档位、EWMA goodput、成功/失败计数和时间戳；默认 7 天 TTL、最多 256 条。画像只作为没有显式覆盖时的初始活动档位，不能永久压低全局可探测上限。完整 URL、路径、查询、Cookie 和授权头不会写入画像；缓存损坏或写入失败不会阻止下载。
4. **统一资源预算（已完成第一阶段）。** 实际 Range 请求受全局 lease 限制，HTTP/HLS 任务共享一个全局聚合速度 limiter；URLSession 响应正文再受进程级 16 MiB 缓冲 lease 约束；重试尝试受独立全局槽位限制；part 文件和 HTTP 请求受 FD reservation 限制，作用域返回或抛错前会确定性释放；Range、重试和 FD 等待均按任务轮转。任务或主机的本地限速只会额外收紧，默认值仍需压力矩阵复核。
5. **写盘合并（未实现）。** 继续使用偏移直写和节流 checkpoint；只有磁盘 I/O profiling 证明相邻写合并或有限写缓存能带来净收益时再实现。

### P2：可选的引擎后端

- 抽象 `DownloadEngine`/adapter，使 HTTP Swift、aria2 和未来 Rust 引擎共享任务模型；adapter 只负责能力报告、状态同步和生命周期。
- 只有在需要 BT、Metalink piece hash、SFTP、远程 headless 或成熟协议覆盖时，才评估捆绑 aria2。HTTP-only 场景继续使用 Swift 核心可减少额外进程、RPC、跨语言状态和安装包体积。
- 不复制 aria2 C++ 源码到 Apache-2.0 Swift 核心。aria2 是 GPLv2；若将其作为独立可执行文件随产品分发，需单独处理 GPL 文本、对应源码、第三方声明、构建和升级边界。

## 9. 资源预算建议

可以用下式做粗略预算，而不是把“线程数”当成唯一成本：

```text
peakMemory ~= baseRSS
             + activeRequests × (responseBuffer + writerBuffer + protocolState)
             + taskCache
```

初版应遵守以下约束：

| 项目 | 建议 |
| --- | --- |
| 新安装 HTTP 默认并发 | 1；已有配置不重置。确认资源大、Range 可用且单连接受限后再升到 2/4 |
| 单任务硬上限 | 先保持 64 作为配置校验上限，但不作为默认目标；实际可用上限由全局预算裁剪 |
| 最小单片 | 当前默认 16 MiB；小于两个最小单片的资源直接单连接，后续按基准调节 |
| 响应缓冲 | URLSession 每请求约 1 MiB 高水位，并由进程级 16 MiB lease 预算约束；仍需在真实代理/HTTP2 场景复核 |
| 任务级缓存 | 先从 16-64 MiB 的有界缓存做 A/B，不让缓存无限跟随吞吐增长 |
| checkpoint | HTTP 路径约 2 秒；UI 事件约 250 ms；暂停、退出、分片完成、失败和完成强制保存 |
| 全局连接 | 当前 Range lease 默认上限 16，运行时可更新；仍需结合系统 FD 和多任务基准调节 |
| 全局限速 | 所有活动 HTTP/HLS 任务共享同一个聚合预算；`0` 表示不设置全局上限 |
| 任务/主机限速 | 作为本地附加上限；空值或 `0` 只取消本地上限，不能绕过非零全局上限 |
| 重试与公平 | 重试槽位默认 2；Range、重试和 FD reservation 按任务轮转；本机多任务失败压力已覆盖，公网/代理长时尾延迟仍需复核 |
| FD 低预算 | 每个活动任务至少预留 part 文件和一个请求各 1 个单位，调度上限自动收紧到 `floor(FD 预算 / 2)`；运行时下降会暂停最新的超额任务，避免所有任务同时等待请求槽位 |
| 物理文件 | macOS/APFS 默认稀疏；密集预分配仅在测得碎片或空间策略收益时启用 |

## 10. 验证矩阵与验收标准

### 10.1 必测场景

| 类别 | 场景 |
| --- | --- |
| 协议 | Range 支持/不支持、`Content-Length` 缺失、HTTP/1.1、HTTP/2、代理 |
| 规模 | 1 MiB、64 MiB、256 MiB、4 GiB 以上；已完成前缀和中间空洞恢复 |
| 服务端 | 单连接限速、总带宽限速、每连接限速、首字节延迟、慢尾部、429/503 |
| 正确性 | ETag 变化、错误 `Content-Range`、短响应、超长响应、连接中途断开 |
| 存储 | APFS SSD、外置 HDD、网络文件系统；稀疏和密集文件 |
| 调度 | 1/2/4/8/16 连接、多个任务混跑、暂停/恢复、进程中止后恢复 |
| 资源 | 峰值 RSS、CPU、FD、内核按进程记账的写入字节、`synchronize()` 次数/耗时、事件队列积压 |

### 10.2 每次 A/B 应记录

- 总耗时、goodput、启动到首字节时间、速度 p50/p95；
- 实际 socket/HTTP stream 数、请求数、重试数、状态码分布；
- user/system CPU、峰值 RSS、打开 FD、I/O wait、内核按进程记账的写入字节；需要设备物理写入时另用磁盘 profiling 获取；
- checkpoint 次数和耗时、事件发布/消费耗时；
- 中断恢复后重新下载的字节数、最终 SHA-256 和目标文件大小。

### 10.3 初始判定口径

分片策略只有在同一负载下同时满足以下条件才算“值得启用”：

1. goodput 相对单连接有稳定、可重复的提升；实验阶段可先用 **至少 10%** 作为升档门槛；
2. 峰值 RSS、CPU、FD 和内核记账写入增量没有超过产品预算；设备级写入另以 profiling 复核；
3. 没有新增错误响应、资源错配、数据损坏或恢复丢失；
4. 在提升不再出现或资源超预算时能自动回退到较低并发。

“连接数变多”或“某次测试更快”都不构成性能优化证据。

### 10.4 当前实现验证

在完整 Xcode-beta（`/Applications/Xcode-beta.app`）下，当前 P0/P1 最小闭环及本轮生命周期修复已通过：

```text
CoolDownloadCore: 97 tests passed
CoolDownloadIntegration: 12 tests passed
CoolDownloadManager: 10 tests passed
swift build passed
```

核心测试覆盖小资源普通 GET、关闭分片回退、有限工作队列、自适应升降档、主机画像优先级与隐私边界、全局连接/速度预算、多任务聚合限速、重试槽位、FD reservation、运行时降低 FD 后暂停超额任务、任务轮转公平、进度事件合并、恢复和取消，以及 URLSession metrics 缺失/乱序和晚到指标观察回归；这些是正确性回归，不替代公网 CDN、代理、HTTP/2、HDD/网络文件系统的性能 A/B。

## 11. 最终建议

当前阶段的后续优先顺序应是（P0/P1 最小闭环、FD 动态收缩和本机成功/失败压力基线已落地，但 16 MiB/16 lease 尚无正式公网矩阵结论）：

```text
固定机器运行 CoolDownloadBenchmark，保存成功与失败压力 JSON 基线（已完成，多轮）
  -> 公网 CDN、HTTP/2、代理、HDD/NAS 矩阵 A/B（已完成小样本 CDN/HTTP2；代理与可写 NAS 仍缺环境）
  -> 持久化/事件热路径 profiling（阶段计时与系统 APFS/外置 SSD 重复观测已完成）
  -> 重复存储 A/B，确认记录 JSON/fsync 是否仍需进一步减少写入次数（系统 APFS/外置 SSD 已复测；HDD/NFS 仍缺可写环境）
  -> 用稳定 profiling 结果决定是否把 RTT、错误率窗口、CPU/I/O 压力纳入在线升档
  -> 有证据时再做磁盘缓存/相邻写合并
  -> 按需引入独立 aria2 后端
```

结论不是“分片无效”，而是“分片必须成为受约束、可反馈、可回退的策略”。aria2 已经证明了这条路线；Motrix 已经证明了将成熟引擎与 UI、任务和恢复逻辑隔离的工程价值。CoolDM 可以先在 Swift 核心中实现这两类思想的最小子集，再用真实 CDN、代理、磁盘和多任务矩阵决定是否需要更重的引擎。
