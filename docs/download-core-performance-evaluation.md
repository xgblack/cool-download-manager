# 下载核心性能评估：Motrix 与 aria2

> 更新日期：2026-08-28
> 评估对象：`feat/develop-swift` 分支上的 CoolDownloadManager Swift 下载核心，以及 Motrix Turbo `v2.0.0-beta.27` 和 aria2 当前源码。
> 目标：判断 HTTP 分片下载的真实收益、系统代价，以及哪些设计值得在当前核心中借鉴。

## 结论先行

1. **分片不是必然提速。** 当单连接已经接近链路、CDN 或服务端上限时，增加 Range 连接只会增加握手、调度、缓冲、写盘和服务端压力；单连接被限速、延迟较高或链路利用不足时，多个连接才可能近似叠加吞吐。
2. **当前核心已落地 P0 的受约束分片路径，但还不是动态反馈调度器。** `DownloadService` 会探测资源、按最小分片阈值静态均分范围，再由有限 worker 领取工作并受全局连接预算约束；`dynamicPartCreation` 仍只控制新任务是否启用这条静态分片路径，不代表运行时自适应调度。
3. **本机基准显示“并发收益取决于服务端模型”，同时暴露出状态路径瓶颈。** 高速本机源中，1 连接约 89.7 MiB/s，8 连接约 67.3 MiB/s；每连接约 4 MiB/s 的受限源中，1/2/4/6 连接约为 2.87/5.90/11.80/17.89 MiB/s，8 连接又降至约 11.95 MiB/s。完整 `DownloadService` 的 256 MiB、6 分片测试约 70.9 MiB/s，而绕过状态持久化的等价 Range writer 约 385 MiB/s；后者不是严格的单变量实验，但足以说明高吞吐下 checkpoint、JSON 原子替换、事件发布和 actor 往返需要优先剖析。
4. **最值得借鉴的是 aria2 的“有限工作队列 + 反馈调度 + 资源预算”，而不是把默认连接数调到 64。** Motrix 的主要价值是引擎隔离、RPC 状态同步、进程监督和恢复；实际下载算法来自 aria2。
5. **建议路线：默认单连接或低并发，满足条件后逐步升并发；先降低持久化热路径，再做慢连接再平衡和自适应并发。** 不建议现在直接照搬 aria2 C++ 代码或把 aria2 作为 HTTP-only 的必需进程。

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
- **本机可控 HTTP 源基准**：256 MiB 本机文件，分别测试高速源和每连接限速源；可证明趋势，不能代表公网 CDN、HTTP/2、代理或真实磁盘。
- **未覆盖**：公网多 CDN、跨地域 RTT、HTTP/2 多路复用、真实 HDD/网络文件系统、系统休眠和大量任务混跑。因此“默认值”和“收益阈值”仍需要产品基准矩阵确认。

## 2. 当前 Swift 核心基线

### 2.1 下载调用链

1. `DownloadService.run` 创建 `PartFileWriter`，恢复已有记录，并建立每个任务共享的 `DownloadRateLimiter`（[DownloadService.swift:580-620](../Sources/CoolDownloadCore/DownloadService.swift#L580-L620)）。
2. HTTP 任务在需要时先发送 `Range: bytes=0-0` 探测；不支持 Range 或响应不符合约定时回退到普通 GET（[HTTPDownloader.swift:102-129](../Sources/CoolDownloadCore/HTTPDownloader.swift#L102-L129)）。
3. `downloadHTTPWithRanges` 根据已知总大小、ETag/Last-Modified 和 `Accept-Ranges` 决定是否并行（[DownloadService.swift:850-902](../Sources/CoolDownloadCore/DownloadService.swift#L850-L902)）。
4. `makeHTTPParts` 按连接上限和最小分片阈值静态均分整个文件；已有文件长度只映射为每个范围的已下载前缀（[DownloadService.swift:938-1002](../Sources/CoolDownloadCore/DownloadService.swift#L938-L1002)）。
5. 当前 P0 只创建有限数量的 worker。worker 从 `HTTPRangeWorkQueue` 领取未完成范围，实际请求再从 `HTTPRangeConnectionBudget` 获取 lease；每个请求使用精确 Range 和 `If-Range`，并通过 `PartFileWriter.write(_:at:)` 写入固定偏移（[HTTPRangeScheduler.swift:12-125](../Sources/CoolDownloadCore/HTTPRangeScheduler.swift#L12-L125)、[DownloadService.swift:963-1052](../Sources/CoolDownloadCore/DownloadService.swift#L963-L1052)、[HTTPDownloader.swift:275-359](../Sources/CoolDownloadCore/HTTPDownloader.swift#L275-L359)）。慢连接再平衡和运行时增加工作单元仍属于 P1。

配置口径需要区分：`DownloadSchedulerConfiguration` 的构造默认值是 1 个连接，macOS 应用启动时会先读取 `AppSettingsModel.threadCount` 再应用到核心；当前实现已将新安装设置的默认连接上限调整为 1。已有用户保存的线程数不自动重置（[Models.swift:36-50](../Sources/CoolDownloadCore/Models.swift#L36-L50)、[Settings.swift:50-63](../Sources/CoolDownloadCore/Settings.swift#L50-L63)、[AppStore.swift:62-77](../Sources/CoolDownloadManager/State/AppStore.swift#L62-L77)、[AppStore.swift:874-885](../Sources/CoolDownloadManager/State/AppStore.swift#L874-L885)）。

### 2.2 已有优点

| 能力 | 现状 | 价值 |
| --- | --- | --- |
| 响应校验 | 校验状态码、`Content-Range`、`Content-Length`、ETag/Last-Modified，超长或短响应都会失败 | 防止错误 Range 或资源替换导致文件静默损坏 |
| 并发写入 | actor 串行化 `FileHandle`，但每次写入使用明确偏移 | 不需要下载完再拼接临时分片文件 |
| 文件准备 | 支持稀疏和密集两种准备方式；稀疏模式只扩展逻辑长度 | 适合 APFS，避免无谓的零填充 |
| 背压 | URLSession 正文通道高水位 1 MiB、低水位 512 KiB，消费者慢时暂停 data task（[NetworkPolicy.swift:48-183](../Sources/CoolDownloadCore/NetworkPolicy.swift#L48-L183)） | 避免响应数据无限堆积 |
| 限速 | 一个任务共享一个 `DownloadRateLimiter`，不是每个分片各限一份（[RateLimiter.swift:1-44](../Sources/CoolDownloadCore/RateLimiter.swift#L1-L44)） | 分片数变化不会突破任务级限速 |
| 恢复安全 | 启动时把没有活跃 Task 的 `downloading/preparing/retrying` 标记为 paused，并保留 part 文件（[DownloadService.swift:42-65](../Sources/CoolDownloadCore/DownloadService.swift#L42-L65)） | 进程崩溃后不会伪装成仍在下载 |

### 2.3 已实施的 P0 变化

当前实现已加入最小分片阈值、全局 Range 连接预算、有限 worker 队列和分离的进度事件/checkpoint 节奏。已有非空 `parts` 不会自动重切分；新任务的小文件和单连接任务走普通 GET。以下风险表描述的是 P1 反馈调度和进一步 profiling 前仍存在的边界。

### 2.4 当前主要瓶颈和风险

| 位置 | 观察 | 影响 |
| --- | --- | --- |
| [DownloadService.swift:1056-1082](../Sources/CoolDownloadCore/DownloadService.swift#L1056-L1082) | 新布局已受最小分片阈值和 128 个范围硬上限约束；仍没有主机画像或链路反馈 | P1 需要根据实际吞吐继续调节并发 |
| [DownloadService.swift:965-1003](../Sources/CoolDownloadCore/DownloadService.swift#L965-L1003) | 已改为有限 worker 队列；当前失败会结束本次任务，尚未做慢连接接管和局部重试 | P1 再增加未开始工作单元再平衡 |
| [DownloadService.swift:1125-1195](../Sources/CoolDownloadCore/DownloadService.swift#L1125-L1195) | 网络进度、250ms UI 事件和 2s checkpoint 已分离 | 仍需用 profiling 确认 JSON/fsync 是否为首要瓶颈 |
| [Storage.swift:130-180](../Sources/CoolDownloadCore/Storage.swift#L130-L180)、[Storage.swift:205-231](../Sources/CoolDownloadCore/Storage.swift#L205-L231) | 每次保存都 JSON 编码、创建临时文件、写入、`FileHandle.synchronize()`、原子替换；分片元数据另写一个 sidecar | 高吞吐下 fsync、临时文件和全记录编码可能比偏移写入更贵 |
| [NetworkPolicy.swift:422-441](../Sources/CoolDownloadCore/NetworkPolicy.swift#L422-L441) | URLSession 同主机连接配置至少为 64 | 这是上限配置，不等于实际建立 64 条连接，也不是任务级连接预算 |
| [DownloadService.swift:1249-1255](../Sources/CoolDownloadCore/DownloadService.swift#L1249-L1255) | `dynamicPartCreation` 只控制新任务是否采用配置线程数，范围仍由静态 `makeHTTPParts` 生成 | 设置名容易让人误以为已有运行时动态调度 |

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

### 4.1 条件

- 本机 `127.0.0.1` 可控 HTTP/1.1 源，文件 256 MiB，支持 `Content-Range` 和 ETag。
- 高速源用于观察并发上限；受限源对每条连接设置约 4 MiB/s，用于观察叠加效果。
- `Bench` 走完整 `DownloadService`；`DirectBench` 只做等价 Range writer，绕过记录持久化和进度事件。
- 数值来自 2026-08-27 的临时 probe，不能作为公网性能承诺；运行环境和文件系统缓存会显著影响绝对值。

这些 probe 程序和原始输出未纳入仓库，当前表格只能作为方向性证据，不能作为 CI 回归基线；正式优化前应把可控源、运行参数、CPU/RSS/FD/磁盘指标和多次重复规则固化。

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

这不是严格的火焰图或单变量实验，不能把差值全部归因于一个函数；但它足以把“先剖析状态/持久化路径”排在“继续增加连接数”之前。

另一个重要观察是：URLSession 配置了 8 个逻辑并发时，实际同主机并发约为 6。连接池、协议版本和系统调度会改变物理连接数，不能把 `httpMaximumConnectionsPerHost` 或分片数直接当成真实 socket 数。

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
| 分片布局 | 最小阈值约束下静态等分 | `min-split-size` + PieceStorage 动态领取 | P0 已限制小分片；P1 再做反馈式切分 |
| in-flight 数量 | 有限 worker + 全局 Range 预算 | 命令按需领取，受全局/任务预算约束 | P0 已覆盖连接上限；P1 再做尾部再平衡 |
| 慢连接 | 无再平衡 | 空闲、未写入 segment 可被接管；完成后继续领新 segment | 中高优先级，先做未开始工作单元 |
| 主机经验 | 只有 host 静态设置 | ServerStat 区分单/多连接速度并支持反馈选择 | 中优先级，需 TTL 和隐私边界 |
| 缓冲 | URLSession 通道每请求约 1 MiB 高水位 | aria2 有界写磁盘缓存 | 当前网络背压方向正确；可加任务级总缓存预算 |
| 持久化 | JSON 原子替换 + sidecar；HTTP 进度约 2 s checkpoint、250 ms UI 事件 | SQLite WAL/预编译/行变更跳过 + aria2 session | 当前最可能的高吞吐瓶颈；仍需 profiling 决定是否改存储 |
| 文件分配 | APFS 默认可稀疏，支持 dense | none/prealloc/falloc 等按环境选择 | 借鉴环境感知，不直接复制 Linux 策略 |
| UI 状态 | AsyncStream 事件 | 1 秒活跃、10 秒空闲轮询，通知只作提示 | 事件应可合并，不能让 UI 反压下载循环 |
| 进程恢复 | 同一进程重启后标记 paused | 引擎独立、PID 监督、GID 与数据库双向恢复 | 只在引入外部引擎时借鉴完整模型 |

## 8. 建议实施路线

### P0：先修正收益/代价模型（已完成）

1. **把 `dynamicPartCreation` 改成真实语义。** 当前保留旧设置键以兼容已有配置，UI 已改为“启用 HTTP 分片”；实际语义仍是启用静态 Range 分片，后续可在配置迁移时改成更直观的内部名称。
2. **加入最小分片阈值和连接预算。** 当前默认最小分片为 16 MiB、全局 Range 连接预算为 16；逻辑为：

   ```text
   desired = task override ?? host recommendation ?? global default
   count = min(desired,
               floor(totalBytes / minimumPartBytes),
               perHostLimit,
               globalConnectionBudget)
   ```

   `count == 1` 时直接走普通 GET；资源大小未知、不支持 Range、经过不透明代理或响应不稳定时不要强行分片。当前仍需通过真实基准确认 16 MiB 是否适合公网 CDN。
3. **改为有限工作队列。** 当前只创建有限 worker，工作单元包含范围和已下载偏移，实际 Range 请求受全局 lease 约束；失败会释放 lease，任务级重试重新从持久化进度构建队列。慢连接再平衡仍待 P1。
4. **分离三类状态。** HTTP 普通 GET/Range 路径的网络进度只更新内存，UI 事件约 250 ms 合并，checkpoint 约 2 秒或重要状态转换时保存；暂停、退出、分片完成、失败和完成仍强制刷盘。HLS 仍按分片完成回调保存，未纳入这次高频 HTTP 节流。
5. **先测量再改写盘实现（采集已落地，A/B 待做）。** 可选的 `DownloadMetricsSink` 已记录任务开始/结束资源快照、HTTP 普通 GET/Range/探测请求、收到响应头的首字节时间、重试、checkpoint 和事件发布耗时；`DownloadStore.save` 同时记录 JSON/sidecar 编码字节、逻辑写入字节、内核按进程记账的写入字节、`synchronize()` 次数和完整 checkpoint 耗时。这个内核计数不是设备物理落盘量，也不能证明 fsync 已完成持久化。默认 sink 为 no-op；只有采样运行才承担额外开销。只有 A/B 或 profiling 证明写盘占主要时间后，才考虑单文件 WAL/SQLite。

### P1：让并发具有反馈能力

1. **慢连接再平衡。** 先只接管尚未写入的工作单元；对已写入部分不做中途迁移。剩余工作低于阈值时停止加新连接，避免尾部产生大量小 Range。
2. **自适应并发。** 对单任务维护 1/2/4/8... 的探测阶段，使用滑动窗口比较 goodput、p95 RTT、错误率和 CPU/I/O；只有边际收益达到初始门槛（建议先以 10% 作为实验门槛）才升档，下降时立即回退。这个 10% 只是基准起点，不是公网保证。
3. **主机画像。** 保存协议、主机、连接档位、观测吞吐、失败率和时间戳；TTL 到期或网络环境变化后重新学习。不要保存完整 URL、Cookie 或授权头。
4. **统一资源预算。** 在任务级和全局级同时限制逻辑连接、响应缓冲、打开文件数、重试并发和总速度；当多个任务同时高速下载时，预算必须按全局总量裁剪。
5. **写盘合并。** 对乱序 Range 写入提供有限写缓存或相邻区间合并，避免为了追求顺序而重新复制完整文件；只在磁盘 I/O profiling 证明必要时实现。

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
| 单请求缓冲 | URLSession 正文通道保留约 1 MiB 高水位；任务级总缓冲上限仍待实现 |
| 任务级缓存 | 先从 16-64 MiB 的有界缓存做 A/B，不让缓存无限跟随吞吐增长 |
| checkpoint | HTTP 路径约 2 秒；UI 事件约 250 ms；暂停、退出、分片完成、失败和完成强制保存 |
| 全局连接 | 当前 Range lease 默认上限 16，运行时可更新；仍需结合系统 FD 和多任务基准调节 |
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

在完整 Xcode-beta（`/Applications/Xcode-beta.app`）下，当前 P0 改动已通过：

```text
CoolDownloadCore: 67 tests passed
CoolDownloadIntegration: 12 tests passed
CoolDownloadManager: 10 tests passed
CoolDownloadCore build passed
CoolDownloadIntegration build passed
CoolDownloadManagerNativeMessagingHost build passed
```

核心测试覆盖小资源普通 GET、静态 Range、有限 worker、全局连接预算、进度事件合并、恢复和取消；这些是正确性回归，不替代公网 CDN、代理、HTTP/2、HDD/网络文件系统的性能 A/B。

## 11. 最终建议

当前阶段的优先顺序应是（P0 核心约束与基础指标采集已落地，但尚无新实现后的公网 A/B 结论）：

```text
可控源与公网矩阵 A/B（使用已落地指标）
  -> 持久化/事件热路径 profiling
  -> 慢连接再平衡
  -> 自适应并发和主机画像
  -> 磁盘缓存/写盘细化
  -> 按需引入独立 aria2 后端
```

结论不是“分片无效”，而是“分片必须成为受约束、可反馈、可回退的策略”。aria2 已经证明了这条路线；Motrix 已经证明了将成熟引擎与 UI、任务和恢复逻辑隔离的工程价值。CoolDM 可以先在 Swift 核心中实现这两类思想的最小子集，再用真实 CDN、代理、磁盘和多任务矩阵决定是否需要更重的引擎。
