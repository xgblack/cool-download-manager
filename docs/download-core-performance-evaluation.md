# 下载核心性能评估：Motrix 与 aria2

> 更新日期：2026-08-29
> 评估对象：`feat/develop-swift` 分支上的 CoolDownloadManager Swift 下载核心，以及 Motrix Turbo `v2.0.0-beta.27` 和 aria2 当前源码。
> 目标：判断 HTTP 分片下载的真实收益、系统代价，以及哪些设计值得在当前核心中借鉴。

下载设置、进度界面和大小文件策略的统一产品口径见[下载调度概念与处理流程](download-scheduling-concepts.md)；本文保留实现证据、开源项目对比和性能基准。

## 结论先行

1. **分片不是必然提速。** 当单连接已经接近链路、CDN 或服务端上限时，增加 Range 连接只会增加握手、调度、缓冲、写盘和服务端压力；单连接被限速、延迟较高或链路利用不足时，多个连接才可能近似叠加吞吐。
2. **当前核心已经具备受约束的反馈闭环。** `DownloadService` 探测资源后创建有界 Range 工作块，worker 按 1/2/4/8 风格档位试探，实际请求受全局 lease、响应缓冲、重试和文件描述符预算约束；不满足收益或延迟条件时会回退。它仍不是 aria2 那种可迁移已写 segment、综合 RTT/CPU/I/O 的完整调度器。
3. **新安装的单任务最大连接数设为 8，但不强制建立 8 个请求。** 自动任务仍从 1 个活动请求开始并按收益试探。系统 APFS 256 MiB 中位 goodput 为 1/2/4/8/16 连接的 `3655/2211/2153/2122/2092 MiB/s`；4 GiB 中位值为 `3593/2170/1946 MiB/s`（1/4/16 连接）。外置 USB APFS SSD 也从 `724 MiB/s`（1 连接）降到 `494-511 MiB/s`（2-16 连接）。因此 8 是产品允许的可探测上限，不是性能保证。
4. **受限源和总带宽上限证明了“条件式收益”。** 每连接约 4 MiB/s 的夹具中，1/2/4/8/16 连接中位 goodput 为 `3.80/6.22/7.80/7.73/7.79 MiB/s`；总带宽固定为 16 MiB/s 时，各档均为 `15.86-15.95 MiB/s`。因此增加连接只能在单连接确实受限时带来收益，不能作为固定打满的策略。
5. **阶段 2～4 的最终决定是保留当前阈值、暂不增加反馈信号、暂不实现写缓存。** 16 MiB 在受限 A/B 中优于 32 MiB（`11.94` 对 `7.45 MiB/s`）；全局 16 与 8 lease 同负载中位吞吐相差约 1.8%，但 16 的服务端并发和 FD 更高，因此 16 只作为共享上限和余量，不是目标并发。项目继续保持纯 Swift HTTP/HLS 核心，aria2 仅作为设计研究对象。

## 1. 范围、版本与证据

### 1.1 取样版本

| 对象 | 取样版本 | 取样方式 |
| --- | --- | --- |
| CoolDownloadManager | `248183be`，`feat/develop-swift` | 当前仓库源码 |
| Motrix Turbo | `6a77297effcde5e72b1cb9f62a4b04cdf2a1db65`，`v2.0.0-beta.27` | `agalwood/Motrix` |
| aria2 | `9e7273583f83e881e3ec067b523ba88724088d2f` | `aria2/aria2` |

Motrix 和 aria2 的源码快照分别见：

- [Motrix commit](https://github.com/agalwood/Motrix/tree/6a77297effcde5e72b1cb9f62a4b04cdf2a1db65)
- [aria2 commit](https://github.com/aria2/aria2/tree/9e7273583f83e881e3ec067b523ba88724088d2f)

### 1.2 证据强度

- **源码证据**：用于还原调用链、状态机、配置边界和资源管理。
- **本机可控 HTTP 源基准**：仓库内 `CoolDownloadBenchmark` 使用生产 `DownloadService`、流式回环 HTTP/1.1 Range 源和独立子进程运行矩阵，校验输出内容并采集 goodput、TTFB、响应 p95、失败响应、重试、CPU、RSS、FD、checkpoint、协商协议和实际服务端并发。正式报告通常为 1 次 warmup 加 3 次测量；进程恢复报告是单次生命周期正确性检查。
- **外部源基准**：同一工具支持 `--url`、可选 `--proxy-url`、挂载点 `--downloads-root` 和 SHA-256 校验；本轮使用 Cachefly（HTTP/2）和 OVH（HTTP/1.1）100 MiB 文件，并对 OVH 经过本机代理复测。报告只保留协议/主机摘要，不写入完整 URL、查询参数、凭据或本机路径。HTTP/2 是否出现以 URLSession 任务指标为准，而不是由连接数推断。
- **证据边界**：系统 APFS 和外置 USB APFS SSD 已完成重复 A/B；USB HDD 与 NAS/NFS 目标目录在当前测试用户下不可写，因此明确记为“无法验证”。公网样本只有两个端点和一个本地代理路径，不能代表所有区域、供应商或生产代理。`responseP95Milliseconds` 是请求完整响应时长的 p95，不等同于网络 RTT；设备物理落盘量也未由内核进程写入计数代替。

## 2. 当前 Swift 核心基线

### 2.1 下载调用链

1. `DownloadService.run` 创建 `PartFileWriter`，恢复已有记录，并建立每个任务共享的 `DownloadRateLimiter`（[DownloadService.swift:580-620](../Sources/CoolDownloadCore/DownloadService.swift#L580-L620)）。
2. HTTP 任务在需要时先发送 `Range: bytes=0-0` 探测；不支持 Range 或响应不符合约定时回退到普通 GET（[HTTPDownloader.swift:102-129](../Sources/CoolDownloadCore/HTTPDownloader.swift#L102-L129)）。
3. `downloadHTTPWithRanges` 根据已知总大小、ETag/Last-Modified 和 `Accept-Ranges` 决定是否并行（[DownloadService.swift:991-1268](../Sources/CoolDownloadCore/DownloadService.swift#L991-L1268)）。
4. `makeHTTPParts` 在连接上限和最小分片阈值内创建最多 `连接上限 × 4`、总计不超过 128 个持久化工作单元；已有文件长度映射为每个范围的已下载前缀。这样快 worker 完成后可以继续领取尚未开始的单元，但不会抢占已经写入中的 Range（[DownloadService.swift](../Sources/CoolDownloadCore/DownloadService.swift)）。
5. worker 从 `HTTPRangeWorkQueue` 领取范围，`HTTPRangeConcurrencyController` 按完成工作单元的聚合 goodput 在 1/2/4/8 风格档位升降，收益不足 10%、吞吐下降或请求失败时回退；实际请求还必须从 `HTTPRangeConnectionBudget` 获取全局 lease。每个请求使用精确 Range 和 `If-Range`，并通过 `PartFileWriter.write(_:at:)` 写入固定偏移（[HTTPRangeScheduler.swift](../Sources/CoolDownloadCore/HTTPRangeScheduler.swift)、[HTTPDownloader.swift](../Sources/CoolDownloadCore/HTTPDownloader.swift)）。

配置口径需要区分：`DownloadSchedulerConfiguration` 的无配置构造兜底是 1 个连接，macOS 应用启动时会读取 `AppSettingsModel.threadCount` 作为单任务连接天花板；新安装默认天花板为 8，已有用户保存的线程数不自动重置。自动任务仍从 1 个活动请求或主机画像档位开始试探。连接上限优先级为 **任务显式覆盖 > 主机显式覆盖 > 全局线程设置**；没有显式覆盖的自动任务会把主机学习画像作为**初始活动档位**，但画像不能永久缩小可探测上限。最终实际 Range 请求数还会被文件大小、剩余工作单元和全局 lease 预算裁剪（[Models.swift](../Sources/CoolDownloadCore/Models.swift)、[Settings.swift](../Sources/CoolDownloadCore/Settings.swift)、[AppStore.swift](../Sources/CoolDownloadManager/State/AppStore.swift)）。

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

## 4. 正式基准证据

### 4.1 条件、口径与报告索引

- 正式报告位于 [Benchmarks/results/2026-08-29/](../Benchmarks/results/2026-08-29/)。普通矩阵为 schema 4，进程中止/恢复为 schema 1；每个普通矩阵均为 1 次 warmup 加 3 次测量，测量在独立子进程中完成。
- 机器和系统由报告记录为 arm64、14 个逻辑处理器、macOS Version 27.0 (Build 26A5421a)。本机夹具是并发发送队列的流式 HTTP/1.1 Range 服务，输出按确定性内容或外部 SHA-256/长度校验；表中 goodput 是下载字节除以完整运行墙钟时间。
- 下表使用同一报告内 3 次测量的中位数；MiB/s 保留两位小数，资源数值用于显示量级而非跨机器预算。responseP95Milliseconds 是完整 HTTP 请求从开始到结束的 p95，包含传输时间，不是 RTT。kernelAccountedWriteBytes 是进程被内核记账的写入增量，不是设备物理落盘量。
- 主矩阵和尺度：[system-apfs-256m-final.json](../Benchmarks/results/2026-08-29/system-apfs-256m-final.json)、[system-apfs-4gib.json](../Benchmarks/results/2026-08-29/system-apfs-4gib.json)、[system-apfs-1mib.json](../Benchmarks/results/2026-08-29/system-apfs-1mib.json)。
- 受限与预算：[system-apfs-64m-per-connection-4mibps.json](../Benchmarks/results/2026-08-29/system-apfs-64m-per-connection-4mibps.json)、[system-apfs-64m-global-16mibps.json](../Benchmarks/results/2026-08-29/system-apfs-64m-global-16mibps.json)、[system-apfs-256m-four-tasks-global8.json](../Benchmarks/results/2026-08-29/system-apfs-256m-four-tasks-global8.json)、[system-apfs-256m-four-tasks-global16.json](../Benchmarks/results/2026-08-29/system-apfs-256m-four-tasks-global16.json)。
- 阈值与延迟：[system-apfs-256m-minpart-16-c8-limited.json](../Benchmarks/results/2026-08-29/system-apfs-256m-minpart-16-c8-limited.json)、[system-apfs-256m-minpart-32-c8-limited.json](../Benchmarks/results/2026-08-29/system-apfs-256m-minpart-32-c8-limited.json)、[system-apfs-64m-ttfb-200ms.json](../Benchmarks/results/2026-08-29/system-apfs-64m-ttfb-200ms.json)。
- 存储与故障：[usb-ssd-apfs-256m-final.json](../Benchmarks/results/2026-08-29/usb-ssd-apfs-256m-final.json)、[system-apfs-256m-four-tasks.json](../Benchmarks/results/2026-08-29/system-apfs-256m-four-tasks.json)、[system-apfs-64m-four-task-retry-pressure.json](../Benchmarks/results/2026-08-29/system-apfs-64m-four-task-retry-pressure.json)、[system-apfs-256m-process-recovery.json](../Benchmarks/results/2026-08-29/system-apfs-256m-process-recovery.json)。
- 公网与协议：[public-cachefly-100m-http2.json](../Benchmarks/results/2026-08-29/public-cachefly-100m-http2.json)、[public-ovh-100m-direct.json](../Benchmarks/results/2026-08-29/public-ovh-100m-direct.json)、[public-ovh-100m-local-proxy.json](../Benchmarks/results/2026-08-29/public-ovh-100m-local-proxy.json)。

### 4.2 系统 APFS：并发增加没有稳定收益

system-apfs-256m-final.json 为 256 MiB、最小工作块 16 MiB、单任务、连接上限 1/2/4/8/16。Range 请求数是实际 Range 数据请求数，不是连接数；server max 是夹具观察到的同时数据请求数。

| 请求连接上限 | goodput 中位 (MiB/s) | Range 请求中位 | response p95 (ms) | checkpoint 总耗时中位 (ms) | 峰值 RSS (MiB) | 峰值 OS FD | server max |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 3655.49 | 0 | 64.9 | 4.00 | 23.8 | 10 | 1 |
| 2 | 2211.38 | 8 | 14.8 | 6.31 | 32.5 | 12 | 2 |
| 4 | 2152.94 | 16 | 15.9 | 9.67 | 34.6 | 16 | 4 |
| 8 | 2121.85 | 16 | 30.0 | 10.26 | 30.8 | 24 | 8 |
| 16 | 2091.93 | 16 | 28.4 | 10.13 | 28.7 | 24 | 8 |

所有 15 个测量均 verified=true、无失败响应和重试。16 的请求上限没有产生 16 个同时请求，控制器实际最高观察到 8；这说明“设置线程数”“Range 工作块数量”和“当前实际请求数”是三个不同指标。相对 1 连接，2/4/8/16 的 goodput 分别下降约 39.5%/41.1%/42.0%/42.8%，而 Range、FD 和 checkpoint 成本上升。

1 MiB 报告中 1/4/16 的 goodput 中位为 62.50/75.16/60.85 MiB/s，所有档位都只发普通 GET、没有 Range 数据请求；小文件不应为了“用满线程”强行分片。

### 4.3 大文件与外置 APFS SSD

4 GiB 系统 APFS 报告的 goodput 中位为 3593.19/2169.73/1946.25 MiB/s（1/4/16 连接），均校验通过；4 和 16 连接分别只有 1/4 与 1/8 的实际并发。文件变大没有把并发劣势变成收益。

外置 USB APFS SSD 报告（256 MiB、同样 1/2/4/8/16 档）如下：

| 请求连接上限 | goodput 中位 (MiB/s) | checkpoint 总耗时中位 (ms) | 峰值 RSS (MiB) | 峰值 OS FD |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 723.87 | 6.09 | 31.5 | 10 |
| 2 | 493.57 | 9.38 | 38.7 | 12 |
| 4 | 498.89 | 13.63 | 39.5 | 16 |
| 8 | 503.14 | 13.64 | 40.5 | 24 |
| 16 | 511.12 | 14.31 | 41.3 | 24 |

系统卷和外置 SSD 都显示单连接最快；外置卷的 4/8/16 档 checkpoint 约为单连接的 2.2-2.4 倍。当前没有可写的 USB HDD 或 NAS/NFS 挂载点，因此这两类存储是**无法验证**，不能从 APFS 结果推断其最佳值。

### 4.4 受限源、总带宽和首字节延迟

- 每连接约 4 MiB/s（64 MiB、最小工作块 8 MiB）的 goodput 中位为 3.80/6.22/7.80/7.73/7.79 MiB/s（1/2/4/8/16）。收益在 4 连接附近平台化；所有输出校验通过，说明分片只有在单连接确实受限时才有条件收益。
- 总带宽固定 16 MiB/s（生产全局限速器、1/2/4/8）的 goodput 中位为 15.95/15.89/15.86/15.90 MiB/s。增加请求没有突破总上限，且 Range 档位的 checkpoint 与响应等待更高。
- 每个响应首字节延迟固定 200 ms（64 MiB、最小工作块 8 MiB）时，1/2/4/8/16 的 goodput 中位为 255.51/48.35/57.12/56.89/57.84 MiB/s；1 连接走普通 GET，只承担一次延迟，分片后每个 Range 都承担延迟。这是夹具模型，不是公网 RTT，但证明高首字节成本会改变最佳档位。

### 4.5 最小工作块 A/B

在同一 256 MiB、单任务、8 连接、每连接 4 MiB/s 的受限夹具中，只改变最小工作块：

| 最小工作块 | goodput 中位 (MiB/s) | Range 请求中位 | checkpoint 总耗时中位 (ms) | server max | 校验 |
| ---: | ---: | ---: | ---: | ---: | --- |
| 16 MiB | 11.94 | 16 | 65.55 | 12 | 3/3 |
| 32 MiB | 7.45 | 8 | 73.65 | 6 | 3/3 |

16 MiB 比 32 MiB 高约 60.2%，因此保留 16 MiB。高速本机源的 8/16/32 MiB 对比会受工作单元数量和控制器升降档共同影响，不能替代这个单变量受限 A/B。

### 4.6 全局 Range lease A/B

system-apfs-256m-four-tasks-global8.json 与 global16.json 使用同一 4 任务、每任务请求上限 4、256 MiB 的负载，只改变全局 Range lease：

| 全局 lease | aggregate goodput 中位 (MiB/s) | server max | 峰值 OS FD 中位 | 校验 |
| ---: | ---: | ---: | ---: | --- |
| 8 | 1600.64 | 8 | 27 | 3/3 |
| 16 | 1572.39 | 16 | 43 | 3/3 |

16 lease 比 8 lease 低约 1.8%，但服务端并发和 OS FD 明显更高。16 作为跨任务共享**安全上限和余量**保留，不是应该主动打满的并发目标；没有证据把它提高到 32 或 64。

### 4.7 多任务、公网协议与恢复

- 4 个任务的系统 APFS 基准（256 MiB/任务、全局 16）aggregate goodput 中位为 4079.99/2955.60/2731.73/2696.23 MiB/s（每任务上限 1/2/4/8）。任务级完成统计显示 4 个任务均完成且校验通过；连接增加仍降低总吞吐并拉长完成 p95。
- 低 FD/重试压力（4 任务、64 MiB/任务、全局 lease 8、FD reservation 8、首 4 个数据请求返回 503、最多 3 次尝试）每个档位的 3 次测量均为 4 个失败响应、4 次重试且最终 verified=true。该报告证明释放和重试预算路径正确，不代表公网错误率。
- Cachefly 100 MiB 的 1/2/4 连接 goodput 中位为 5.06/4.97/5.13 MiB/s，所有请求协商 h2；OVH 直连 HTTP/1.1 为 5.08/5.22/5.14/5.32/5.33 MiB/s（1/2/4/8/16），OVH 本机代理为 5.46/5.36/5.22 MiB/s（1/2/4）。公网样本没有稳定的 10% 级收益，代理增加连接后反而下降，因此不改变默认值。报告只保存脱敏主机摘要，不能代表其他区域或供应商。
- 进程恢复报告显示首进程以状态 9（SIGKILL）结束，中止前已持久化 16 MiB、记录状态为 downloading；新进程启动后将其识别为 paused，续传完成并校验通过。它是恢复正确性证据，不是吞吐基准。

所有正式 JSON 均可解析，普通报告的每次完成输出均 verified=true；旧的 /tmp 临时 probe 不再作为本文数值依据。

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

| 维度 | 当前 Swift | aria2/Motrix | 当前决定 |
| --- | --- | --- | --- |
| 引擎边界 | HTTP/HLS 直接在 Swift actor 内 | Motrix core 与独立 aria2 进程通过 adapter/RPC 隔离 | 保持纯 Swift 单核心；aria2 只作设计参考，不增加 adapter、RPC 或第二套状态源 |
| Range 正确性 | 校验状态码、范围、长度、验证器并按偏移写入 | piece/segment 状态、重试和校验成熟 | 保留现有校验，继续借鉴局部 piece 状态 |
| 分片布局 | 最小阈值下创建有限工作单元，快 worker 可继续领取未开始单元 | min-split-size 加 PieceStorage 动态领取 | 已满足当前需求；暂不迁移已写入的进行中 Range |
| 活动请求数 | 1/2/4/8 风格 worker，受任务上限和全局 lease 约束 | 命令按需领取，受多级预算约束 | 当前 goodput/请求占用时间/失败控制器足够；没有证据新增 RTT、CPU 或 I/O 信号 |
| 慢连接 | 只对未开始工作做再平衡 | 空闲且未写入 segment 可接管 | 保持安全的粗粒度再平衡，避免重复写 |
| 主机经验 | 协议/主机/端口画像，7 天 TTL、最多 256 条，不保存 URL 路径和凭据 | ServerStat 区分单/多连接速度 | 画像只作为自动任务初始档位，不永久压低可探测上限 |
| 限速 | 任务/主机 limiter 叠加全局聚合 limiter | aria2 有全局和单任务限速 | 保持全局硬上限和本地附加上限语义 |
| 缓冲 | 每请求约 1 MiB 高水位，进程级响应预算 16 MiB | aria2 有界写磁盘缓存 | 网络背压和响应预算已足够；任务级写缓存暂不实现 |
| 重试与 FD | 重试槽位默认 2；part 文件和 HTTP 请求共享 FD reservation，按任务轮转 | aria2 有多级资源控制 | 本机低 FD/503 压力已验证；继续区分 reservation 与 OS 实际 FD |
| 持久化 | JSON 原子替换；现代记录内嵌 parts，旧格式/已有 sidecar 才兼容写回 | SQLite WAL、预编译语句和 session | 保持轻量 JSON；没有存储 profiling 证据时不迁移 WAL/SQLite |
| 文件分配 | APFS 默认可稀疏，支持 dense | 按环境选择 none/prealloc/falloc | 只记录环境建议，不把 Linux 策略直接复制到 macOS |
| UI 状态 | AsyncStream 事件，约 250 ms 合并 | 活跃/空闲轮询，通知只作提示 | UI 更新不反压下载循环；当前连接数展示活动 HTTP 请求而非物理 socket |
| 进程恢复 | 重启时将陈旧 downloading 标记为 paused，保留 part 文件 | PID 监督、GID 与数据库双向恢复 | 本地 SIGKILL/续传已验证；不引入外部引擎状态同步 |

## 8. 执行计划结果

### 阶段 1：补齐性能证据

**状态：已完成可用环境验证；不可用环境明确留空。**

已完成固定机器上的单任务、多任务、1 MiB/256 MiB/4 GiB、1/2/4/8/16 连接、单连接限速、总带宽限速、首字节延迟、低 FD 与 503 重试、HTTP/2、HTTP/1.1、直连、代理、外置 APFS SSD 和进程中止恢复。所有正式报告均保留最终长度或摘要校验，普通矩阵每次完成均 verified=true。当前用户下 USB HDD 和 NAS/NFS 目标目录不可写，因此这两项结论为“无法验证”，不能用 APFS 结果替代。

### 阶段 2：决定默认阈值与预算

**状态：已完成；阈值与预算保留，产品默认连接上限后续调整为 8。**

- 最小工作块保留 16 MiB：在相同受限源 A/B 中为 11.94 MiB/s，32 MiB 为 7.45 MiB/s，16 MiB 优势约 60.2%，三次测量全部校验通过。
- 全局 Range lease 保留 16：四任务同负载下，8 lease 中位 1600.64 MiB/s，16 lease 中位 1572.39 MiB/s；16 没有带来速度收益，却把 server max 从 8 提到 16、峰值 OS FD 从 27 提到 43。16 是共享安全上限和跨任务余量，不是目标并发。
- 新安装的单任务最大连接数调整为 8；已有用户设置不自动重置。该值只扩大自动控制器的可探测上限，自动任务仍从 1 开始；受限源可在试探到 2/4 后获得收益，但高速源、代理和外置 SSD 均未证明持续使用 8 个请求稳定更快。

### 阶段 3：按证据完善在线反馈

**状态：本轮不触发，不新增代码。**

正式矩阵没有证明当前控制器稳定选错档位或回退过晚。公网和代理样本反而显示收益不稳定；现有 goodput、请求占用时间和可恢复失败信号已经能回退。未来若出现重复误判，应先离线分析协议指标、请求 p95 和错误窗口，再一次只加入一个信号。

### 阶段 4：按证据优化写盘路径

**状态：本轮不触发，不新增代码。**

系统 APFS 和外置 APFS SSD 的 checkpoint 计时已可观测，现代记录也已去除固定 sidecar 写入；现有结果没有证明偏移写、JSON 或同步是稳定的首要瓶颈。没有可写 HDD/NAS/NFS 的设备级 I/O 证据前，不实现任务级写缓存、相邻写合并、WAL 或存储模型迁移。内核进程写入计数不能替代物理设备 profiling。

### P2：外部引擎后端

**状态：取消。**

不抽象 DownloadEngine adapter，不集成或分发 aria2，不增加外部 RPC、BT、Metalink、SFTP、远程 headless 或第二套任务状态。Motrix/aria2 源码只保留为有限工作队列、反馈调度、恢复和资源预算的研究依据。

## 9. 当前资源与默认值

| 项目 | 当前决定 |
| --- | --- |
| 新安装 HTTP 默认最大连接数 | 8；已有配置不重置，自动任务仍从 1 个活动请求开始试探 |
| 单任务配置上限 | 64 仅作为校验硬上限，不是默认目标；实际活动请求受工作单元和全局 lease 裁剪 |
| 最小 Range 工作块 | 16 MiB；小文件或不满足 Range 条件时走普通 GET |
| 全局 Range lease | 16；跨任务共享安全上限，不主动打满，也不提高到 32/64 |
| 响应缓冲 | 每请求约 1 MiB 高水位，进程级总预算 16 MiB；等待预算的请求不创建 socket |
| 任务级写缓存 | 暂不实现，等待可写 HDD/NAS/NFS 或大文件 profiling |
| HTTP checkpoint | 约 2 秒、或新增约 64 MiB、或重要状态转换；暂停、退出、分片完成、失败和完成强制保存 |
| UI 事件 | 约 250 ms 合并；显示当前活动 HTTP 请求数与设置上限，不宣称物理 TCP 连接数 |
| 全局限速 | 所有 HTTP/HLS 活动任务共享聚合上限；0 表示不设置全局上限 |
| 重试与公平 | 重试槽位默认 2；Range、重试和 FD 等待按任务轮转 |
| FD 低预算 | 每个活动任务至少保留一个 part 文件和一个请求 reservation，活动任务上限按 FD 预算自动收紧 |
| 文件准备 | macOS/APFS 默认稀疏；密集预分配只在有碎片或空间策略证据时启用 |

16 和 16 MiB 都是当前证据下的保守可解释值，不是物理定律或全场景最优值。重新调整必须使用同负载、至少三次测量、最终内容校验和资源边界同时满足的 A/B 证据。

## 10. 验证与验收

### 10.1 正式报告

正式目录包含 27 个脱敏 JSON：26 个 schema 4 普通矩阵和 1 个 schema 1 恢复报告。每个普通矩阵都有 1 次 warmup 和 3 次测量；所有完成输出 verified=true。报告已记录 goodput、首字节时间、完整请求 p95、请求/重试/失败计数、协议、checkpoint 分阶段耗时、CPU、RSS、FD、内核记账写入和夹具服务端并发。

旧的 schema 4 报告缺失新增配置、协议、分阶段 checkpoint 或任务统计字段时，解码器使用与新运行一致的空值/默认值；这保证历史报告仍能用于纵向比较。

### 10.2 已验证与无法验证

- **已验证**：本机 APFS、外置 USB APFS SSD、受限/总限速/延迟/失败压力、HTTP/1.1、HTTP/2、OVH 直连、OVH 本机代理、低 FD 预算、暂停/取消边界和 SIGKILL 后续传。
- **无法验证**：当前测试用户没有可写 USB HDD 和 NAS/NFS 挂载点；因此没有把存储类型自动调优或写缓存结论写成实现。
- **不适用**：物理 TCP 连接数和设备实际落盘量不能由逻辑 Range 请求数、URLSession 配置或进程内核写入计数直接推出。

### 10.3 代码验证命令

在完整 Xcode-beta 下执行：

    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --disable-sandbox
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --disable-sandbox
    git diff --check

测试需要覆盖普通 GET、Range 校验、调度升降档、预算/重试/FD、公平性、持久化、恢复和取消；性能报告不替代这些正确性测试。

## 11. 最终建议

本轮执行已完成所有有条件的阶段，当前不再有需要立即修改的性能算法：

1. 新安装的单任务最大连接数使用 8，同时保持 16 MiB 最小工作块和全局 16 lease；不要因为上限为 8 就主动创建 8 个 Range 请求。
2. 保持现有自适应 worker、背压、全局限速、重试/FD 预算、轮转公平和节流 checkpoint；这些机制解决的是“收益出现时可用、收益消失时回退”。
3. 将正式 JSON 作为后续回归基线。新增公网区域、代理供应商、可写 HDD/NAS/NFS 或不同 macOS 版本时，先复跑同一矩阵，再决定是否改变阈值。
4. 只有重复 profiling 证明写盘路径限制 goodput，才选择一种有界写优化并重新验证恢复；在此之前不加入缓存或更重的存储层。
5. 只有重复证据显示控制器持续选错档位，才新增一个在线反馈信号；不为理论上的 RTT/CPU/I/O 优化预先增加复杂度。
6. aria2 后端及 P2 协议扩展保持取消状态，避免把性能问题重新包装成引擎集成问题。

结论仍然是：分片不是越多越快。它应当是受资源预算约束、由实测收益驱动、可以回退且能通过内容校验的策略。
