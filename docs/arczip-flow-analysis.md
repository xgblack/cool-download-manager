# ArcZip 1.1.5 「Flow」上下文快捷操作 —— 功能机制分析与可复刻实现说明

> 分析对象：`/Users/xgblack/Downloads/ArcZip-1.1.5-273.dmg`（挂载后 `ArcZip.app`，CFBundleVersion 273，1.1.5，最低系统 macOS 14.0）
> 分析方式：读取应用包内的可执行文件与随包资源（类型信息、常量、本地化文本、SQLite 表结构、XPC 接口约定），并与界面文案、设置项、系统框架的公开语义交叉印证；未运行目标程序。
> 用途：为其他下载器复刻「下载完成后按文件类型给出一步到位操作」提供实现级参考。本文只描述 ArcZip 的做法，不涉及你方项目实现。

---

## 0. 一页结论

ArcZip 把「选中内容 → 该做什么」抽象成一个叫 **Flow** 的动作系统：

1. **Flow 是"带条件的动作候选"**。每个候选由固定 ID 标识，本版本共 **13 个**：11 个可执行动作 + 2 个设置项 ID（见 §2.2）。
2. **上下文（FlowContext）** 由三项决定：当前打开的容器（压缩包/磁盘映像）、文件索引里的**选中项**、以及用户设置（格式白名单、Pro 授权）。
3. 解析后得到 **1 个主操作（isPrimary）+ 若干备选**，UI 用轨道控件（FlowOrbit）展示；「另有 N 个备选 Flow」展开其余动作。
4. 动作执行器分四类，**同一套 Flow 抽象覆盖**：
   - 解压类：`extract-all / extract-selection / extract-directory`（内置 7zz / bsdtar）
   - 安装类：`install.application / install.font / install.package`（**Pro**）
   - 打开类：`open.file / open.disk-image-application / open.installed-application`
   - 兜底：`unavailable`、`add-files`
5. **安装 .app 的真实做法**：从容器取出 .app（压缩包走 7zz `x -aos …`；DMG 走 `copyfile(2)` + 进度）→ 结构校验（`Contents/Info.plist`、`CFBundlePackageType == APPL`、`CFBundleExecutable` 存在且可执行）→ 代码签名/公证分级（Security.framework，分"未签名/临时签名/未公证/来源不明"四档弹窗）→ 在**目标卷**上的隐藏暂存目录（`.arczip-install-`）准备 → 无旧版 `moveItem`、有旧版 `replaceItemAt` 原子替换（失败可回滚）→ 在**最终路径**上 `removexattr("com.apple.quarantine", XATTR_NOFOLLOW)` → 按设置保留/移入废纸篓源压缩包、可自动关窗。
6. **安装字体**：白名单 `otf/ttf/ttc`（`lowercased` 后比较）→ `CTFontManagerCreateFontDescriptorsFromURL` + `CFArrayGetCount≥1` 验证 → `copyItem` 到 `~/Library/Fonts/.arczip-font-<UUID>` → 清 quarantine → 无旧版 `moveItem`、有旧版 `replaceItemAt` → `CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeUser, &err)`。注意：它**忽略注册返回值、注册失败也不回滚**（复刻时可以做得更好）。
7. **DMG 快速安装**：`hdiutil attach -plist -puppetstrings -readonly -nobrowse -noautoopen -owners off -mountpoint <自建目录> <dmg>`（密码走 `-stdinpass` 写 stdin），用 **PTY** 接 stderr 解析进度行；卸载 `hdiutil detach -force <mountPath>`，并删除 `<卷名>.owner.json` / `.launch.json` 标记。映像内按"`Contents/Info.plist` + `APPL`"识别 app，按 `Applications` 替身/自定义落地目录判定开发者意图，给出四类告警（仅"直接打开"路径）。
8. **设计上最值得抄的三点**：
   - 动作 ID 是稳定字符串（如 `app.arczip.install.application`），文案与行为解耦，便于本地化与灰度。
   - 所有"危险/耗时"动作都走 `FlowTaskRegistry` 统一登记，避免并发重复执行（如"创建中的压缩包不能解压"）。
   - 容器索引（SQLite）里直接把 `is_auxiliary` / `is_dmg_applications_shortcut` / `is_disk_image_background` 作为列，UI 过滤与"批量解压时跳过辅助文件"共用同一份判定。

---

## 1. 证据等级与阅读方式

本文每条结论都尽量给出可复核的证据。标记约定：

| 标记 | 含义 |
|---|---|
| **【观测】** | 直接从应用包资源与可执行文件中读到的字面量、符号、选择器、SQL、命令行参数，几乎不会错 |
| **【强推断】** | 由观测到的调用序列 + 系统 API 语义推出的行为，出错概率低 |
| **【推断】** | 由文案、类名、状态字段推出的顺序/策略，可能有细节差异，需要实测确认 |
| **【未知】** | 仅凭文件内容无法确定（例如某些容器格式下的分支、被内联掉的参数） |

证据引用格式：`fn 0x1008dd774`（arm64 切片内的函数起始地址）、`"文案"`（本地化 key）、`sel:xxx:yyy:`（Objective-C 选择器）、`stub:_xxx`（导入符号）。

文件构成（供复核）：
- 主程序：`ArcZip.app/Contents/MacOS/ArcZip`（universal，arm64 + x86_64，代码段约 9.8 MB，符号表已剥离、不提供函数名）
- XPC：`Contents/XPCServices/ArcZipArchiveService.xpc/Contents/MacOS/ArcZipArchiveService`（约 8.4 MB，保留部分符号）
- 扩展：`Contents/PlugIns/ArcZipFinderSync.appex`、`Contents/PlugIns/ArcZipQuickLook.appex`
- 内置解压引擎：`Contents/Resources/7zz`（7-Zip 26.04）

---

## 2. 产品模型：Flow 到底是什么

### 2.1 概念

**Flow = 针对"当前选中内容"的一个可执行动作 + 它的展示信息（标题/说明/可用性/是否主操作）。**

它不是"右键菜单"，因为：
- 候选集合由**内容**决定（压缩包里有 .app → 出现"安装应用"；选中字体文件 → 出现"安装字体"；选中普通文件 → 出现"打开文件"）。
- 同一个动作在不同上下文有不同的**标题与说明**（例：DMG 里已挂载的 app，若用户设置"优先打开"，标题变成"交给 macOS 打开此应用"，否则是"安装到"应用程序"文件夹"）。
- 有**主/备**关系，UI 只突出一个。

### 2.2 动作目录（13 个稳定 ID）【观测】

从应用包内的字符串常量可完整取出（`fn 0x1008e1544`…`fn 0x1008e16d4` 为各 case 的 `rawValue` getter）：

| # | FlowActionKind rawValue | 语义 | 典型上下文 |
|---|---|---|---|
| 1 | `app.arczip.archive.add-files` | 添加文件到压缩包 | 可编辑的压缩包会话 |
| 2 | `app.arczip.archive.extract-all` | 全部解压 | 已索引完成的压缩包 |
| 3 | `app.arczip.archive.extract-selection` | 解压所选项目 | 选中 ≥1 个条目 |
| 4 | `app.arczip.archive.extract-directory` | 解压文件夹 | 选中单个目录条目 |
| 5 | `app.arczip.install.application` | 安装应用（.app） | 选中/首个条目是 macOS 应用程序包 |
| 6 | `app.arczip.open.disk-image-application` | 打开磁盘映像里的应用 | DMG 内 app，用户选择"直接打开" |
| 7 | `app.arczip.install.font` | 安装字体 | 选中 otf/ttf/ttc |
| 8 | `app.arczip.install.package` | 安装 PKG | 选中 .pkg/.mpkg |
| 9 | `app.arczip.open.installed-application` | 打开已安装的应用（/Applications 中已存在） | 目标已安装 |
| 10 | `app.arczip.open.file` | 打开文件（解到临时目录后交给默认应用） | 选中普通文件且格式在允许列表 |
| 11 | `app.arczip.unavailable` | 不可操作（占位/解释原因） | 链接、设备节点、加密未解锁、索引中、创建中 |
| 12 | `app.arczip.open-file.allowed-extensions` | "打开文件"的格式白名单配置项 ID | 设置页 |
| 13 | `app.arczip.disk-image.application.prefers-open` | "优先打开而非安装"的配置项 ID | 设置页 |

> 前 11 个是"可执行动作"，后 2 个是**设置项 ID**，被同一套 ID 空间统一管理（见 §8）。

### 2.3 五种"动作形态"（决定执行成本）

从类名可辨识（`__swift5_typeref`/`_TtC` 字符串）【观测】：

| 定义类型 | 说明 | 需要索引完成 | 需要解压 |
|---|---|---|---|
| `ExtractAllFlowDefinition` | 对整个容器操作 | 是 | 是 |
| `MultipleSelectionFlowDefinition` | 对多选条目操作 | 是 | 是 |
| `FocusedEntryFlowDefinition` | 对单个条目操作（含 install.*、open.file） | 是 | 是（先取出该条目） |
| `DraftArchiveFlowDefinition` | 对"正在创建的压缩包"操作 | — | 否（直接拒绝） |
| `DiskImageApplicationFlowConfiguration` | 对 DMG 内 app 的两种动作（install / open） | 是 | 是（copyfile） |

另有 `ApplicationFlowInference`（推断容器里的"那个应用"是谁）与 `ApplicationFlowDefinition`。

---

## 3. 架构总览

### 3.1 进程与职责【观测】

```
ArcZip.app (SwiftUI 主程序, com.maczhang.ArcZip)
├── ArcZipFinderSync.appex      Finder 右键：快速压缩/快速解压/快速解压到…/发送到 ArcZip
├── ArcZipQuickLook.appex       压缩包预览（内嵌同一套 ArchiveEngines）
├── ArcZipArchiveService.xpc    真正的解压/读取执行器（XPC，ServiceType=Application）
└── Resources/7zz               7-Zip 26.04 CLI（内置引擎之一）
```

- 主程序**不做重活**：解压/读取压缩包、挂载 DMG、把条目落盘，都在 `ArcZipArchiveService` 里（XPC 客户端见类 `ArcZipXPCClient`、响应管道 `ArcZipXPCResponseSink`）。
- XPC 服务**校验调用方**，要求字符串【观测，见 XPC 服务的字符串常量】：
  ```
  identifier "com.maczhang.ArcZip" and anchor apple generic and certificate leaf[subject.OU] = "J5W6R92F8U"
  ```
  即：只有同 TeamID(J5W6R92F8U) 签名、Apple 锚定的 ArcZip 才能连。
- 解压引擎抽象：`ArchiveEngineBroker` + 多个引擎实现（7zz / libarchive(bsdtar) / 原生 ZIP / 磁盘映像）。引擎 ID 字面量：`system-disk-images`、`system-libarchive`、`system-libarchive-lzip`、`bundled-compressed-stream`。

### 3.2 模块划分【观测，来自 Swift 类型前缀】

| 模块 | 关键类型（节选） |
|---|---|
| `ArcZipFlows` | `FlowDefinition` / `ExecutableFlow` / `FlowActionKind` / `FlowActionDescriptor` / `FlowActionState` / `FlowContext` / `FlowContextValue` / `FlowRegistry` / `FlowResolver` / `FlowInvocation` / `FlowNoDecision` / `FlowTaskRegistry` / `FlowPreferences` / `FlowSettingsProviding` / `FlowSettingDescriptor` / `FlowSettingsRegistry` / `CommercialFlowPolicy` / `AppInstallFlowDefinition` / `FontInstallFlowDefinition` / `InstallerPackageFlowDefinition` / `OpenFileFlowDefinition` / `ApplicationFlowInference` |
| `ArcZipApp` | `FlowActionRouter` / `FlowCompletionPresenting` / `FinderFlowCompletionPresenter` / `AppModel` / `ArchiveBrowsingSession` / `ApplicationLandingModel` / `DiskImageApplicationLaunchCoordinator` / `QuarantinePolicy` / `SourceArchiveCompletionCoordinator` |
| `ArcZipUIShared` | `FlowOrbitControl` / `FlowOrbitLayout` / `FlowOrbitPresentation` / `FlowOrbitPhase` / `FlowOrbitPointerTracker` |
| `ArcZipDialogKit` | 通用对话框、进度窗、密码框（`ArcZipNativeAlertAnchor` 等） |
| `ArchiveCore` | `ArchiveFormat` / `EntryIndex` / `DiskImageArtwork` / `DiskImagePresentation` / `AuxiliaryEntryClassifier` / `ArcZipStorage` / `ManagedTemporaryArtifactRegistry` |
| `ArchiveEngines` | `ArchiveEngineBroker` / `SevenZipExtractionProgressEmitter` / `BSDTarProgressReporter` / `HDIUtilDiskImageMountDriver` / `SystemHDIUtilCommandRunner` / `DiskImageMountProgressBroadcaster` / `DiskImageReadSessionProvider` / `ProcessTerminationWaiter` |
| `ArcZipCommerce` | `EntitlementManager` / `CommercePersistence` / `SecureURLSessionTransport`（Pro 授权） |

### 3.3 容器索引：为什么"值得扫一遍再动作"

主程序内置 SQLite（`libsqlite3` + WAL）用于**把压缩包内容索引成可查询表**，Flow 依赖它判断"里面有 .app / 字体 / 目录"。【观测，schema 字面量】

```sql
CREATE TABLE IF NOT EXISTS entries (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    is_auxiliary INTEGER NOT NULL,              -- __MACOSX / .DS_Store / ._* / Thumbs.db …
    is_disk_image_background INTEGER NOT NULL,  -- DMG 背景图/卷图标等
    is_dmg_applications_shortcut INTEGER NOT NULL, -- DMG 里指向 /Applications 的"替身"
    payload BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entries_path ON entries(path COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_entries_path_exact ON entries(path COLLATE BINARY);

CREATE TABLE IF NOT EXISTS directory_nodes (
    canonical_path TEXT PRIMARY KEY,
    parent_path TEXT NOT NULL,
    sort_name TEXT NOT NULL,
    is_directory INTEGER NOT NULL,
    is_virtual INTEGER NOT NULL,
    is_auxiliary INTEGER NOT NULL,
    is_disk_image_background INTEGER NOT NULL,
    is_dmg_applications_shortcut INTEGER NOT NULL,
    payload BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_directory_nodes_parent_exact
    ON directory_nodes(parent_path COLLATE BINARY, is_directory DESC, sort_name COLLATE NOCASE);

CREATE TABLE IF NOT EXISTS archive_publications ( ... state, plan, bookmark, volume_uuid ... );
CREATE TABLE IF NOT EXISTS temporary_artifacts ( ... purpose, kind, ownership_token, device_id, inode, birth_seconds ... );
PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;
PRAGMA user_version=2;
```

要点：
- **辅助项分类**落库而不是每次现算（`AuxiliaryEntryClassifier` 决定），因为"浏览时是否显示""批量解压是否跳过""DMG 安装辅助文件是否跳过"三处都要用。
- `is_dmg_applications_shortcut` 是**DMG 专用**列：用来把"Applications 快捷方式"从文件树里识别出来，既用于隐藏它，也用于判断"开发者期望你拖到 /Applications"。
- `temporary_artifacts` 以 `(device_id, inode, birth_seconds)` 记账，配合 `ownership_token` 做**孤儿清理**（崩溃后仍能安全删除自己创建的临时文件）。

---

## 4. 上下文（FlowContext）：动作是怎么被"算出来"的

### 4.1 上下文字段【观测 + 强推断】

从 Swift 反射字段名（`__swift5_reflstr`）可确认 `FlowContext` / `FlowContextValue` 及 `FlowActionDescriptor` 承载以下语义字段：

| 字段 | 含义 | 用途 |
|---|---|---|
| `context` / `contextRevision` / `contextSignature` | 上下文快照与版本签名 | 缓存键：只有签名变化才重算 Flow 列表 |
| `selection` / `selectionCount` / `selectionRoots` / `currentSelection` / `emptySelection` | 选中项与根 | 决定 extract-selection / install.* / open.* 的候选 |
| `entryID` / `entryPath` / `path` | 选中条目路径 | 决定扩展名、目录判断、包内相对路径 |
| `format` / `archiveFormat` | 容器格式与压缩包内该条目的"格式" | 决定引擎与过滤策略 |
| `isEncrypted` | 条目/容器是否加密 | 未解锁时只允许"输入密码"，安装/打开需先解锁 |
| `isIndexing` / `isReady` / `isComplete` | 索引状态（后台索引中 / 部分可用 / 完成） | 未完成时动作被禁用（"索引完成后即可安装"） |
| `availability` / `availabilityObservation` | 可用性观察（异步依赖，如挂载状态、Pro 授权） | 驱动 `FlowActionState` |
| `requirements` / `requiresPro` / `includesFlowRequirement` | 前置条件集合（Pro、索引完成、可写、已安装） | 门控与提示文案 |
| `isPrimary` / `primary` / `priority` | 主操作标记与优先级 | UI 只突出主操作 |
| `signingRequirement` / `appleAnchorRequirementFailed` | 签名要求（用于校验 XPC 对端与自身） | 安全边界 |
| `requirementEvaluationNanoseconds` | 条件求值耗时 | 性能埋点（说明条件求值是热路径，需要缓存） |

### 4.2 候选推导规则【强推断】

对一次"选中 N 个条目"的事件，ArcZip 的解析逻辑等价于：

```
候选 = []
if 容器正在创建:
    候选 += [DraftArchiveFlowDefinition]            # 只会产出 unavailable + "创建中的压缩包不能解压"
elif 容器是磁盘映像(DMG/ISO) 且 顶层发现 .app:
    候选 += [install.application (Pro), open.disk-image-application]
elif 容器是压缩包:
    候选 += [extract-all if 索引完成]
    if N >= 1: 候选 += [extract-selection]
    if N == 1 and 条目是目录: 候选 += [extract-directory]
    if N == 1 and 条目是 .app 包: 候选 += [install.application]
    if N == 1 and 条目是 字体(otf/ttf/ttc): 候选 += [install.font]
    if N == 1 and 条目是 .pkg/.mpkg: 候选 += [install.package]
    if N >= 1 and 全部条目都在白名单格式: 候选 += [open.file]
if 没有候选:
    候选 += [unavailable]
按 priority 排序 → 取第一个为 isPrimary，其余为备选
```

**关键细节（均可用文案与设置项交叉验证）：**

1. **"打开文件"受白名单限制**：设置项 `openFile.allowedFormats.v1`，文案 `"允许打开的文件格式"`、`"只有明确选中的格式才会显示"打开文件" Flow"`。
2. **加密未解锁时不出安装动作**，而是出现需要密码的路径：文案 `"安装加密压缩包中的应用"`、`"安装加密压缩包中的字体"`、`"准备加密压缩包中的安装包"`。说明流程是"先提示输入密码 → 解锁 → 继续安装"。
3. **索引未完成时动作存在但被禁用**，并给出原因：`"索引完成后即可安装"`、`"索引完成后即可全部解压"`、`"文件索引完成前暂不能解压项目"`。
4. **链接/特殊文件不可操作**：`"ArcZip 不直接操作链接或特殊项目"`、`"不可直接操作"`（fn `0x1008ea454`）。这与"条目类型"枚举有关：`符号链接`、`硬链接`、`设备节点`、`Unix 套接字`、`命名管道（FIFO）`、`特殊项目` 都会落到 unavailable。
5. **DMG 内 app 有"优先打开/优先安装"偏好**：`app.arczip.disk-image.application.prefers-open`（fn `0x1008e9d9c` 中该 key 与 `app.arczip.open.disk-image-application`、`app.arczip.install.application`、`app.arczip.open.installed-application` 一起被读取）。

### 4.3 主操作矩阵（"下载完成后该推荐什么"）

把 §4.2 的推导压成一张表，这就是 ArcZip 对"当前内容"的**默认推荐**（`isPrimary`）。标注【推断】的部分来自文案与优先级字段，而非逐条代码确认。

| 当前内容 / 选中 | 主操作 | 备选 | 备注 |
|---|---|---|---|
| 压缩包（无选中） | `extract-all`（"全部解压"） | — | 索引未完成时禁用并提示"索引完成后即可全部解压" |
| 压缩包 + 选中 1 个目录 | `extract-directory`（"解压文件夹"） | `extract-all`、`open.file`（若白名单命中） | — |
| 压缩包 + 选中 ≥1 个文件 | `extract-selection`（"解压所选项目…"） | `extract-all`、`open.file` | — |
| 压缩包 + 选中 .app | `install.application`（"安装应用"，Pro） | `extract-selection` | 未授权时点主操作 → Pro 弹层 |
| 压缩包 + 选中字体 | `install.font`（"安装字体"，Pro） | `extract-selection` | — |
| 压缩包 + 选中 .pkg | `install.package`（"安装 PKG"，Pro） | `extract-selection` | 交给系统 Installer |
| 压缩包 + 选中普通文件（白名单内） | `open.file`（"打开文件"，Pro） | `extract-selection` | 解到临时目录后交给默认应用 |
| DMG（含单个 .app） | `install.application`（Pro，"快速安装"） | `open.disk-image-application` | 受 `app.arczip.disk-image.application.prefers-open` 影响：置真时主操作变成"交给 macOS 打开此应用" |
| DMG（含多个 .app） | 打开/浏览 | 逐个安装 | 触发 `multiple_destinations` 告警 |
| DMG（无 .app） | 浏览 | 解压（如需） | — |
| 普通文件（下载器场景：非容器） | 用系统默认应用打开 / 显示所在位置 | — | ArcZip 作为压缩工具不覆盖这一类；复刻时这是你新增的能力 |
| 不可操作项（链接/设备节点/加密未解锁/创建中） | `unavailable` | — | 必须给出原因文案，而不是空菜单 |

> **对下载器的直接启示**：这张表就是"下载完成后该显示哪几个按钮"的答案。你只需要实现第 1、4、5、6 行与 DMG 两行，就能覆盖"dmg / app / 字体 / 压缩包"四类需求。

### 4.4 "推断是哪个 app"（ApplicationFlowInference）

压缩包/映像里可能有多个 .app，或没有 .app 只有安装包。ArcZip 的处理：

- 目录树里**取最浅层、非辅助**的 `.app` 作为主要候选（`is_auxiliary = 0` 且 `is_dmg_applications_shortcut = 0`）。
- 若是"推断"（例如压缩包里没有直接 .app，但有 `Payload/`、或 app 在子目录里），标题退化为带引号的通用文案：
  - `flow.install_application.inferred.help` = `"Install “%@” in the Applications folder"`（中文原文以同 key 存储）。
- 若已经安装到 `/Applications` 且版本相同，候选中会出现 `app.arczip.open.installed-application`（"打开已安装的应用"），文案 `"已安装 "`。

---

## 5. Flow 的展示（用户看到的交互）

### 5.1 轨道控件（FlowOrbit）【观测】

`ArcZipUIShared/FlowOrbitControl.swift` 及相关类型：`FlowOrbitLayout`、`FlowOrbitPresentation`、`FlowOrbitPhase`、`FlowOrbitAction`、`FlowOrbitHoverLabel`、`FlowOrbitPointerTracker`、`FlowOrbitRequest`、`FlowOrbitConfiguration`。

行为要点：
- 主操作是**大按钮**（图标 + 标题），鼠标悬停显示帮助（`FlowOrbitHoverLabel`）。
- 备选折叠为"另有 %lld 个备选 Flow"（key `flow.alternative_count`），可展开/收起（key `"展开备选 Flow"` / `"收起备选 Flow"`）。
- 支持键盘：`"按回车键执行"`、`"按空格键执行"`、`"按空格也可预览"`。
- 分辨率/布局：`FlowOrbitLayout` 负责计算轨道半径与项间距；`FlowOrbitPhase` 是动画阶段机（出现/悬停/展开/收起），说明它做的是"轨道展开动画"而非普通按钮组。
- 不可用时按钮禁用并显示原因；Pro 动作显示 `FoldspaceFlowProBadge`（Pro 徽标）。
- 悬停/指针状态会被记录（`flowHoveredActionID`、`flowPointerEngaged`），用于埋点与避免误点。

### 5.2 动作执行与并发控制【观测】

- `FlowActionRouter.executeFlow(...)` 负责把 descriptor 派发到具体 handler；执行前登记到 `FlowTaskRegistry`（字段 `flowTasks`、`flowAuthorizationTask`、`runningFlowActionKinds`、`resumesFlow`、`flowCloseWork`、`flowCloseRevision`）。
- 这解释了：同一动作重复点击不会并发执行；关闭窗口时等待任务（`flowCloseWork`）。
- 完成后由 `FlowCompletionPresenting` 呈现结果：主程序用 `FlowCompletionPresenter`，Finder 扩展用 `FinderFlowCompletionPresenter`（说明**同一动作在 Finder 扩展里也能触发并汇报结果**）。

---

## 6. 设置与授权门控

### 6.1 与 Flow 相关的偏好键（UserDefaults / 自定义存储）【观测】

| 键 | 类型 | 默认/说明 | 关联文案 |
|---|---|---|---|
| `applicationInstallation.quickInstall.v1` | Bool | 是否在 DMG 里"快速安装"（Pro） | `"快速安装应用"`、`"安装到"应用程序"文件夹"` |
| `applicationInstallation.completedArchiveAction.v1` | 枚举 | 安装完成后如何处理源压缩包 | `extraction.completion.always_ask / always_keep / always_trash` |
| `applicationInstallation.automaticallyClosesArchive.v1` | Bool | 安装完成后自动关窗 | `archive.completion.auto_close` |
| `openFile.allowedFormats.v1` | 集合 | "打开文件"允许的格式 | `"允许打开的文件格式"` |
| `extraction.completedArchiveAction.v1` | 枚举 | 解压后处理源压缩包 | `extraction.completion.*` |
| `extraction.automaticallyClosesArchive.v1` | Bool | 解压后自动关窗 | — |
| `extraction.filtersSystemAuxiliaryFiles.v1` | Bool | 过滤 `__MACOSX/.DS_Store/._*/Thumbs.db/desktop.ini` 等 | `settings.extraction.auxiliary.short` |
| `extraction.filtersDMGInstallerArtifacts.v1` | Bool | DMG 专用：过滤隐藏项 + Applications 替身 | `settings.extraction.dmg.short`、`"自动过滤 DMG 安装辅助文件"` |
| `extraction.extractsOnExternalOpen.v1` | Bool | 双击压缩包直接解压（跳过浏览） | `extraction.opening.direct` |

> 命名规律：`<域>.<语义>.v<版本>`。带 `.v1` 是为了将来迁移（读不到旧键就用默认值）。

### 6.2 Pro 门控【观测】

- 政策类型：`CommercialFlowPolicy`（字段 `commercialFlowPolicy`、`includesFlowRequirement`）。
- 免费可用（原文）：`"打开、浏览、预览、完整解压，以及通用分享 + ZIP + 均衡强度的基础压缩"`。
- 被门控时统一弹层文案：
  - `commercial.pro.feature_requires_pro` = `"“%@”属于 ArcZip Pro。免费版仍可使用打开、浏览、预览、完整解压，以及通用分享 + ZIP + 均衡强度的基础压缩。"`
  - `commercial.pro.search_requires_pro`（包内搜索）
  - `commercial.pro.feature_flows_title` = `"All Pro Flows"`
- 结论：**安装应用 / 安装字体 / 安装 PKG / 打开文件 / 快速安装(DMG) 属于 Pro**；`完整解压`、`打开磁盘映像里的应用` 属于免费能力。
- 授权状态机（供参考，不必复刻）：`EntitlementManager` + 7 天试用，状态含 `trial_ended / revoked / refunded / invalid / license_unavailable / upgrade_required`。

### 6.3 Flow 设置页【观测】

- 页面类型：`FlowSettingsPage`、行控件 `FlowSettingsRegistry` / `FlowSettingsDescriptor` / `FlowSettingDescriptor` / `FlowToggleSettingOptionRow` / `FlowChoiceSettingOptionRow` / `FlowFileFormatSettingOptionRow`。
- 每个 Flow 在设置页有：标题 + 说明 + 若干开关/下拉项。
  - 安装应用：`"从压缩包安装 macOS 应用"` + 说明 `"安装 App 时移除应用根目录已有的下载隔离标记"`
  - 安装字体：`"安装到当前用户的字体库"`
  - 安装 PKG：`"安全准备后交给 macOS 安装器"`
  - 打开文件：`"解压单个文件到受管理的临时目录，并使用系统默认应用打开"` + 格式白名单
  - 全部解压：`"索引完成后即可全部解压"`
  - 解压所选：`flow.extract_selection.help`
- 全局开关：`"展示 Flow 可执行的操作"`（标题）、`Flow 快捷操作`（分区名）、`"Flow 会根据压缩包内容，推荐此刻最合适的操作。"`（说明）。

---

## 7. 安装 macOS 应用（.app）—— 全链路解析

这是本功能的重点。ArcZip 把"从压缩包/磁盘映像里装 app"拆成**五个阶段**，每个阶段都有独立失败语义和文案。

### 7.1 阶段划分

```
S0 识别      : 上下文判定"这是个 app 安装动作"（Flow: app.arczip.install.application）
S1 提取/取源 : 把 .app 从容器里弄到本地暂存区（压缩包→解压；DMG→copyfile）
S2 结构校验  : .app 是否真的是可运行的 bundle
S3 安全检查  : 代码签名 / 公证状态 → 决定是否需要用户二次确认
S4 落位      : 拷贝进 /Applications（同名替换，失败回滚）
S5 收尾      : 去 quarantine、可选打开、处理源压缩包、关窗
```

### 7.2 S1：从压缩包提取（ExtractApplicationBundle）

【观测】Flow 层有专门的"解包"入口，编码字段名即操作名：

- `extractApplicationBundle` / `extractApplicationBundleEntries`（Codable 键 `ExtractApplicationBundleCodingKeys`、`ExtractApplicationBundleEntriesCodingKeys`）
- `extractDiskImageItem`（从映像取单个条目）
- `applicationBundleByteCount` / `applicationBundleByteCounts` / `applicationBundleByteCountTasks` → **先统计字节数**（用于进度条与磁盘空间预检）

实现要点（强推断，结合 `ArchiveEngines` 与临时区设计）：
1. 先算出该 `.app` 子树的总字节数（`applicationBundleByteCount`），用于进度与"磁盘空间不足"预检（文案 `"磁盘空间不足"`、`"空间不足"`）。
2. 解压到**受管理的临时目录**（`ManagedWorkFileStore` / `ManagedTemporaryArtifactRegistry` / `ArcZipStorage`），目录带所有权令牌（`ownership_token`）与 inode 记账，保证崩溃后能清理。
3. 加密压缩包：先弹密码（`"安装加密压缩包中的应用"`、`"准备加密压缩包中的安装包"`），再把密码传给解压引擎（`-p` 参数，sentinel `__ARCZIP_NO_PASSWORD__` 见 §9）。
4. 解压结果必须是**单个 .app bundle**，否则报错（见 7.3）。

> 复刻建议：不要试图流式安装（边解边拷），因为 S2 的 bundle 结构校验要在完整目录上做；且 .app 可能含符号链接与扩展属性，必须用能保留元数据的方式落盘（ArcZip 走 7zz + 后续元数据修补）。

### 7.3 S2：bundle 结构校验（fn `0x1008df62c`）

【观测】该函数按顺序校验，每个失败点有独立文案：

| 检查 | 失败文案（key） |
|---|---|
| 路径存在且是 `.app` 目录 | `"没有生成有效的 .app 应用程序包"` |
| `Contents/Info.plist` 可读且是字典 | `"<名字> 的 Info.plist 无效"` |
| `CFBundlePackageType == APPL` | 同上报错路径（复用同一错误分支） |
| `Contents/Info.plist` 含 `CFBundleExecutable` | `"<名字> 缺少可执行文件"` |
| `Contents/MacOS/<CFBundleExecutable>` 存在且可执行 | 同上 |

另外，Flow 入口还有一层前置判定（fn `0x1008db52c`）：
- `"所选项目不是 macOS 应用程序包"`

> 注意：**先校验再拷贝**，避免把半个 app 放进 /Applications。

### 7.4 S3：代码签名与公证检查

两块独立逻辑，别混淆：

**(a) 自身/XPC 对端校验**（fn `0x100281718`、fn `0x10028199c`）【观测】

用于校验 XPC 客户端与"已安装的 ArcZip"身份，构造的 requirement 字符串是（由多段常量拼接而成）：

```
anchor apple generic and
certificate 1[field.1.2.840.113635.100.6.2.6] exists and
certificate leaf[field.1.2.840.113635.100.6.1.13] exists and
certificate leaf[subject.OU] = "<TEAMID>"
```
调用链：`SecRequirementCreateWithString` → `SecStaticCodeCheckValidity`。
另有更详细的：`SecStaticCodeCreateWithPath` → `SecStaticCodeCheckValidityWithErrors` → `SecCodeCopySigningInformation`，取 `identifier` / `teamid` / `flags`，并产出字段（Swift 属性名可见）：

- `invalidSignature`、`invalidCodeSignature`、`adHocSignature`、`verificationFailed`
- `teamIdentifierMismatch`、`signingIdentifierMismatch`、`bundleIdentifierMismatch`
- `signatureValidationNanoseconds`（性能埋点）

XPC 服务端的固定要求串（观测，见 XPC 服务的字符串常量）：
```
identifier "com.maczhang.ArcZip" and anchor apple generic and certificate leaf[subject.OU] = "J5W6R92F8U"
```

**(b) 待安装 app 的安全分级**（用户确认弹窗）【观测文案 + 推断判定】

| 分级 | 弹窗标题 | 正文/说明 |
|---|---|---|
| 正常（已公证、Developer ID） | `"安装应用？"` | 普通确认（含名称、`"安装到"应用程序"文件夹"`） |
| 未签名（无签名） | `"安装未签名的应用？"` | `install.confirm.unverified.message` = `"无法验证"%@“的开发者。仅在你信任来源时安装。"` |
| 临时签名 / Ad-Hoc | `"安装临时签名的应用？"` | 同上（提示不可验证来源） |
| 已签名但未公证 | `"安装未公证的应用？"` | `install.confirm.unnotarized.message` = `"“%@”尚未通过 Apple 公证。仅在你信任来源时安装。"` |
| 来源不明 | `"安装来源不明的应用？"` | `install.confirm.unverified.title` |

弹窗内还展示两行元信息（观测到的前缀字符串）：
- `"签名状态："` + 状态文本（如 `已由 Apple 公证。` / `无法验证`）
- `"应用标识："` + `CFBundleIdentifier`
- 危险动作按钮：`"仍要安装"`（Install Anyway），安全出口 `"取消"`。

> 【推断】判定顺序大致是：`SecStaticCodeCreateWithPath` 失败(errSecCSUnsigned) → 未签名；成功但 `flags & CS_ADHOC` → 临时签名；成功但 OU/team 为空 → 来源不明；再用"公证 requirement"（`anchor apple generic and certificate 1[field…6.2.6] exists and certificate leaf[field…6.1.13] exists`）二次校验失败 → 未公证；全通过 → 正常。

**默认策略**：这些检查**默认开启**。设置页有对应说明 `"默认关闭，保留系统安全检查"`（另一处相关选项的默认值），说明产品定位是"不鼓励绕过系统安全检查"。

### 7.5 S4：落位到 /Applications

**目标目录解析**（fn `0x1008dd1c4`、`0x1008dd774`、`0x1008dde2c`、`0x1008de720`、`0x1008deaa0`、`0x1008dee20` 六个异步分支共享同一文案）
- 默认 `/Applications`（字面量 `applicationsDirectory`、`/Applications`）
- 若来自 DMG 且映像内有自定义目标（见 §8），按映像指示处理（这时不强行装到 /Applications，而是给告警）

**可写性检查**
- 捕获 `CocoaError.fileWriteNoPermission`（fn 中显式比较 `CocoaErrorV4CodeV21fileWriteNoPermission`）→ 抛 `"没有权限写入"应用程序"文件夹"`。

**同名处理**
- 目标已存在 → 抛 `"目标位置已存在"<name>""`（fn `0x1008dc8d4`），上层转成询问：
  - 标题 `"替换现有应用？"`
  - 正文 `application.install.replace.message` = `"要用压缩包中的版本替换"应用程序"中的“%@”吗？"`
  - 或 `"替换"` / `"取消"`
- 若 `/Applications` 里已有同 bundle id 但版本不同，还会出现 `app.arczip.open.installed-application`（已安装 → 直接打开）。

**拷贝实现**
- **主拷贝**：从容器取出的 .app 归位。压缩包来源走"解到暂存 → 移动到目标"；DMG 来源走 `copyfile(2)`（类 `DiskImageCopyfileContext` 用 `copyfile_state_alloc/set/get` 做进度回调，文案 `"正在从磁盘映像复制应用程序"`）。
- **元数据修补**：fn `0x1008dfdec` 内两次 `copyfile`：
  - `flags = 0x000C0004` → `COPYFILE_XATTR | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST`
  - `flags = 0x040C0004` → 同上 + 一个高位标志（推断为 `COPYFILE_RUN_IN_PLACE`/`COPYFILE_CLONE` 一类）
  - 失败：`"无法完成应用安装元数据：" + strerror(errno)`
  - 另有一条前置错误 `"安装目标不是应用程序目录"`（目标必须仍是 .app 目录，防止竞态替换）
- **暂存命名**：隐藏前缀 `.arczip-install-`（fn `0x1008dcf3c`；同卷暂存是为了后续 `rename(2)` 原子替换）。综合 `replaceItemAt(_:withItemAt:)` 的导入与 `；回滚原因：` 文案，可判断存在"替换失败回滚"分支。

**替换的推荐实现（复刻时照此做）**
```
tmp = <dest volume>/.arczip-install-<random>/<Name>.app    // 同卷，保证 rename 原子
copy(extracted, tmp)                                      // 保留 xattr/ACL/符号链接
verify(tmp)                                               // 再校验一次签名/结构
if exists(dest):
    backup = <dest volume>/.arczip-install-<random>/old.app
    move(dest -> backup)                                  // 或 FileManager.replaceItemAt
    move(tmp -> dest)
    if failed: move(backup -> dest); throw("；回滚原因：" + err)
    remove(backup)
else:
    move(tmp -> dest)
removexattr(dest, "com.apple.quarantine")
```

### 7.6 S5：收尾

1. **去 quarantine**（fn `0x1008df4ec`；主进程唯一 `removexattr` 调用点）【观测】
   ```c
   if (removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0) ok;
   else if (errno == ENOATTR /*93*/) ok;   // 本来就没有 → 视为成功
   else if (errno == ENOENT  /*2*/)  ok;   // 文件已不存在 → 视为成功
   else throw "无法移除“<AppName>”的 com.apple.quarantine";
   ```
   - 两个 errno 白名单很重要：从 DMG 复制的 app 可能本来就没有隔离标记，不能当成失败。
   - 这一步是**产品卖点**：下载来的 app 装好即可运行，没有"从互联网下载"的首次拦截。
2. **完成后处理源压缩包**（设置 `applicationInstallation.completedArchiveAction.v1`）
   - `Ask Every Time` / `Always Keep File` / `Always Move to Trash`
   - 文案组：`application.install.completion.title`=`"安装完成"`、`source_detail`=`"安装完成后保留压缩包或移到废纸篓"`、`trash_failed`=`"安装已完成，但原压缩包无法移到废纸篓：%@"`
3. **可选自动关窗**（`applicationInstallation.automaticallyClosesArchive.v1`，文案 `"安装完成后关闭窗口并保留压缩包"`）。
4. **可选打开刚装好的 app**（文案 `"已安装 "`、`"打开应用"`；以及"建议先安装此应用"分支用于 DMG 直接打开场景）。
5. **结果展示**：`"安装完成"` / `"已安装 " + 名称`；失败按 §7.7。

### 7.7 错误与提示清单（可直接照抄成 UX 文案表）

| 场景 | 文案 key |
|---|---|
| 选中项不是 app | `"所选项目不是 macOS 应用程序包"` |
| 解压未产出 app | `"没有生成有效的 .app 应用程序包"` |
| Info.plist 坏 | `"<名> 的 Info.plist 无效"` / `"应用程序缺少 Info.plist"` |
| 缺可执行 | `"<名> 缺少可执行文件"` |
| 无写权限 | `"没有权限写入"应用程序"文件夹"` |
| 目标已存在 | `"目标位置已存在"<名>""` → `"替换现有应用？"` |
| 元数据拷贝失败 | `"无法完成应用安装元数据：" + errno 文案` |
| quarantine 失败 | `"无法移除"<名>"的下载隔离标记"` |
| 安装后源包处理失败 | `application.install.completion.trash_failed` |
| 磁盘空间不足 | `"磁盘空间不足"` / `"空间不足"` |
| 压缩包创建中 | `"创建中的压缩包不能解压"` / `"创建中的压缩包不能操作"` |
| 索引未完成 | `"索引完成后即可安装"` |
| 加密未解锁 | `"安装加密压缩包中的应用"` |
| Pro 未授权 | `commercial.pro.feature_requires_pro` |

---

## 8. 磁盘映像（DMG / ISO）：挂载、发现、复制、卸载

> 本节证据来自主程序与 XPC 服务两处；挂载/卸载命令在**主程序**里用 `Foundation.Process` 直接执行。

### 8.1 挂载命令：完整 argv【观测】

构造器 `fn 0x1007b4690`（arm64），Swift `[String]` 字面量逐槽写入，顺序即 argv：

```
/usr/bin/hdiutil
  attach
  -plist
  -puppetstrings
  -readonly
  -nobrowse
  -noautoopen
  -owners
  off
  -mountpoint
  <挂载点绝对路径>
  [-noverify]        // 条件参数
  [-stdinpass]       // 条件参数（加密映像）
```

工程细节（这些细节决定复刻成败）：

| 项 | 做法 | 说明 |
|---|---|---|
| 启动方式 | `Process`（`NSTask`）直接 `executableURL = file:///usr/bin/hdiutil` | 不经过 shell，无引号/注入问题 |
| 工作目录 | **不设置** | 全仓无 `currentDirectoryURL` |
| 环境变量 | **整体替换为只含 `PATH` 的字典** | 避免用户 `PATH`/`DYLD_*` 干扰子进程 |
| stdin | `/dev/null`（密码模式例外） | 防止 hdiutil 交互卡死 |
| stdout | `Pipe` | 收 `-plist` 输出 |
| **stderr** | **伪终端（PTY）从端**（`openpty`） | 关键：hdiutil 的进度行是 `\r` 驱动的，走 PTY 才能按行拿到 |

**条件参数一 `-noverify`**：由 `认证枚举 == 0xA` 或会话级布尔 `skipVerificationRequests`/`skipsVerification` 决定 —— 即"跳过校验"是**会话级**策略，不是每次弹窗。

**条件参数二 `-stdinpass`**：加密映像时，密码通过 **stdin 写入（密码 + `\n`）**，不出现在 argv。写完后把该缓冲清零（防泄漏）。

> 对比：解压路径的密码是走 argv 的 `-p<密码>`（见 §11.6），DMG 路径更谨慎。

### 8.2 进度与结果解析

- **不解析 hdiutil 的 plist 键名**（应用包内不存在任何 `hdiutil info -plist` 的键字符串），挂载点是自己 `-mountpoint` 指定的，不需要从输出推断。
- 进度靠 `HDIUtilProgressLineParser` 解析 PTY 上的行：内部 `NSLock` + `pendingLine` 缓冲，处理 `\r` 与跨块拼接；`DiskImageMountProgressBroadcaster` 广播百分比。
- 阶段 payload：`ArchiveReadSessionProgressPayload(phase:fraction:isWaitingForExternalMount:)`。

阶段文案（字符串即状态）：

| key | 中文 |
|---|---|
| `"正在挂载磁盘映像"` | Mounting |
| `"正在校验磁盘映像"` | Verifying |
| `"正在确认磁盘映像内容完整"` | Verifying contents |
| `"正在结束校验并重新挂载"` | Finishing verification & remounting |
| `"正在跳过校验"` | Skipping verification |
| `"正在读取磁盘映像的第一层内容"` | Reading first layer |
| `"磁盘映像校验失败"` | Check failed |
| `"磁盘映像挂载已不可用"` | Mount no longer available |
| `"没有权限读取此磁盘映像"` | Access denied |

### 8.3 卸载【观测】

主路径（卸载流程 `fn 0x10079bfc0`）**无条件强制**：

```
/usr/bin/hdiutil detach -force <挂载点绝对路径>     // 3 个元素
```

- 另有**不带** `-force` 的 2 元素构造点（`fn` 内 count=2 的数组 `["detach", path]`），用于不需要强制的场合。
- 卸载后删除两个标记文件：`<挂载目录>/<卷名>.owner.json`、`<卷名>.launch.json`（`removeItemAtURL:error:`），失败即抛错。
- 卸载不做 quarantine 处理、不重试。
- 生命周期：有 `idleGrace` / `allowsIdleGrace` / `cleanupTask` / `cleanupGeneration`，即**空闲宽限期后回收**，而不是用完立刻卸。

### 8.4 外部挂载兼容（别人已经挂上了）

字段与机制（`ArchiveEngines` / `ArchiveCore`）：

- `ExternalMount`、`ExternalMountMetadata`、`externalMountPollingInterval`、`postExternalMountSettleDelay`、`isWaitingForExternalMount`、`diskImageAlreadyMounted`、`DiskImageMountRecoveryPolicy`、`diskImageMountRecoveryFailed`
- 发现：`hdiutil info -plist`（已挂载枚举）+ `NSWorkspaceDidMountNotification`
- 语义：**不抢占**已有挂载；轮询等待 + settle delay（卷内容刚挂上时可能未就绪）

> 复刻要点：轮询间隔与 settle delay 的具体数值未以可读常量出现（推断为秒级），实测建议 200–500ms 轮询、挂载后再等 0.5–1s。

### 8.5 映像内容模型与 .app 发现【观测字段 + 强推断】

模型类型（字段名可读）：

```
DiskImagePresentation {
  authoredWindowBounds, documentCanvasSize, iconSize, background, backgroundSettings,
  items, dropDestinations, rootEntryScanIsComplete, quality,
  permitsWindowAutosizing, hasDeveloperDropDestination, initialWindowSizingHint
}
DiskImagePresentation.Item { type, linkTarget, … , item(forCanonicalPath:) }
DiskImageDropDestination { entryPath, kind, availability, resolvedDirectoryPath }
DiskImageArtwork { representations, preferredRepresentation(maximumPixelSize:), isValid }
```

发现算法（强推断，依据字段与判定文案）：

1. 扫描挂载点：根层（`rootEntryScanIsComplete`）+ 一层展开（`fullEntries`）；大映像先给部分结果（`quality` 降级）。
2. 目录若含 `Contents/Info.plist` 且 `CFBundlePackageType == APPL`，判定为 app；读 `CFBundleExecutable`/`CFBundleIdentifier` 得可执行与标识。
3. 根层符号链接若指向 `/Applications` → `DiskImageDropDestination(kind: .applications, entryPath: "Applications")`；作者自定义落地目录 → `kind: .custom`。
4. 辅助项（`.background/*`、`.VolumeIcon.icns`、`.DS_Store`、`.fseventsd`）落入 `is_auxiliary` / `is_disk_image_background`，既隐藏也不参与安装。

**四类告警**（`fn 0x1000608f8` 内按序构造，仅"直接打开 app"路径触发）：

| 条件 | key | 文案 |
|---|---|---|
| `dropDestinations.count > 1` | `…warning.multiple_destinations` | `"开发者为此应用提供了多个安装位置。建议先按照映像中的拖动指引完成安装。"` |
| 存在 `kind == .applications` | `…warning.applications` | `"开发者建议先将“%@”拖到“应用程序”文件夹，或使用 ArcZip 的快速安装（Pro），再从“应用程序”文件夹打开。"` |
| 存在 `kind == .custom` | `…warning.custom_destination` | `"开发者指定了“%@”作为安装位置。请按映像中的指引先将其拖到该位置。"` |
| 目标 `availability == .unavailable` | `…warning.destination_unavailable` | `"ArcZip 无法确认开发者为“%@”准备的安装位置。继续将直接打开此应用。"` |

### 8.6 从映像复制 .app【观测】

- **复制用 `copyfile(2)`**，不是 `FileManager.copyItem`。薄封装 `fn 0x100787560`：`copyfile(from, to, state, &flags)`，返回值写回 out 参数；源为空时抛"图像项目路径"类错误。
- `copyfile_state_alloc/get/set/free` 用于**统计与进度**（`DiskImageCopyfileContext`）。
- **清 quarantine** 是独立一次 `removexattr`：

```
removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW /*1*/)
  返回 0            → 成功
  errno == ENOATTR(93) → 视为成功（本来就没有）
  errno == ENOENT(2)   → 视为成功（文件没了）
  其他 errno        → 抛 "无法移除“<AppName>”的 com.apple.quarantine"
```
- 该 `removexattr` 调用点**只存在于主程序**（XPC 未导入）→ 清隔离发生在主进程。

### 8.7 端到端状态机（DMG → 安装完成）

| # | 阶段 | 关键动作 | 文案 |
|---|---|---|---|
| 1 | 挂载 | `hdiutil attach …` | `"正在挂载磁盘映像"` |
| 2 | 校验 | hdiutil 自校验 | `"正在校验磁盘映像"` / `"正在确认磁盘映像内容完整"` |
| 3 | 索引 | 根层 + 一层扫描 | `"正在读取磁盘映像的第一层内容"` |
| 4 | 呈现 | 呈现窗口布局/图标/背景 | — |
| 5 | 判定 | 找 app、找落地目标 | 四类告警（仅打开路径） |
| 6 | 复制 | `copyfile` + 进度 | `"正在从磁盘映像复制应用程序"` / `"正在复制 ISO 项目"` |
| 7 | 校验结构 | `Info.plist`/`CFBundlePackageType`/`CFBundleExecutable` | §7.3 |
| 8 | 安全检查 | 签名/公证分级 | §7.4 |
| 9 | 落位 | 同卷暂存 → move/replace | `"安装完成"` |
| 10 | 去隔离 | `removexattr` | — |
| 11 | 打开（可选） | `NSWorkspace.open` | `"已打开应用"` |
| 12 | 卸载 | `hdiutil detach -force`（空闲回收） | `"磁盘映像挂载已不可用"`（异常） |

### 8.8 ISO / 加密映像

- ISO 与 DMG 共用同一驱动（`system-disk-images` 引擎），差异只在检测（`DiskImageArtwork`/文件系统类型）与文案（`"正在复制 ISO 项目"`、`"ISO 项目复制完成"`）。
- 加密 DMG：`-stdinpass` + 密码条目与解压路径共用密码输入 UI；错误文案 `"密码不正确"`。
- 只读浏览（不安装）：挂载后直接建索引，不触发复制/安装。

---

## 9. 安装字体（otf / ttf / ttc）

### 9.1 判定规则【观测】

1. 白名单 `Set<String>` = **`{"otf","ttf","ttc"}`**（`minimumCapacity: 3`；字面量在 `__DATA` 的 3 个小串 `otf/ttf/ttc`）。
2. 取扩展名：`lastPathComponent` → `pathExtension` → **`lowercased()`** → `Set.contains`。大小写不敏感；不含 `otc`、`woff`、`dfont`。
3. 判定输入是**压缩包内条目路径**（在提取前），与 `fontName` 同源。
4. 第二道内容校验（在文件落地后）：`CTFontManagerCreateFontDescriptorsFromURL` 返回非 NULL 且 `CFArrayGetCount >= 1`，否则 `"<文件名> 不是有效的字体文件"`。
5. 字体家族名/PostScript 名**不参与**判定与命名；目标文件名 = 原文件名。

### 9.2 错误清单【观测】

| 触发 | 文案 |
|---|---|
| 选中项不是字体 | `"所选项目不是字体文件"` |
| 扩展名不在白名单 | `"仅支持安装 OTF、TTF 和 TTC 字体"` |
| CoreText 无法解码 | `"<文件名> 不是有效的字体文件"`（注意前导空格） |
| 目标已存在且未确认替换 | `"字体库中已存在“<文件名>”"` |
| `CocoaError.fileWriteNoPermission` | `"没有权限写入当前用户的字体库"` |
| 注册失败 | 原样抛出 `CFError`（无自定义文案） |

### 9.3 目标目录与权限

```
home        = FileManager.default.homeDirectoryForCurrentUser
fontsDir    = home.appendingPathComponent("Library/Fonts", isDirectory: true)
destination = fontsDir.appendingPathComponent(fontName)
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true, attributes: nil)
```
- **没有可写性预检**（全应用范围内未见 `isWritableFileAtPath`），直接靠写失败 + `CocoaError` 映射。
- 不做 `chmod/chown`、不改 ACL、不请求额外授权；写不进去就报错。

### 9.4 安装序列【观测，含一个反直觉的事实】

```
1. ensureDirectory(~/Library/Fonts)
2. copyItem(source → <fontsDir>/.arczip-font-<UUID>/<fontName>)     // 同卷隐藏暂存
3. 清 quarantine：读 URLResourceValues.quarantineProperties，
   若存在则置 nil 并 setResourceValues（等价 xattr -d com.apple.quarantine）
4. if fileExists(destination):
       if userConfirmedReplace: fm.replaceItemAt(destination, withItemAt: staged,
                                                 backupItemName: nil, options: [])
       else: throw "字体库中已存在“<fontName>”"
   else: fm.moveItem(staged → destination)
5. CTFontManagerRegisterFontsForURL(destination, kCTFontManagerScopeUser /* = 2 */, &cfError)
6. if cfError != nil { throw cfError }        // 返回值 bool 被忽略
7. 清理暂存目录
8. UI: "字体安装完成"
```

**必须照抄的三个事实（都是 ArcZip 的真实行为，不是理想化设计）：**
- 替换用 **`replaceItemAt(_:withItemAt:backupItemName:options:)` 原子替换**，不是"先删后拷"；不保留备份（`backupItemName: nil`）。
- **注册失败不会回滚已落地的字体文件**（模块内没有"注册失败→删除"的分支）。复刻时你可以做得更好：注册失败就删除并提示。
- `CTFontManagerRegisterFontsForURL` 返回的 `Bool` 被忽略，只看 `CFError`。

### 9.5 冲突交互

- 标题 `"替换现有字体？"`，正文 `"当前用户的字体库中已经存在“<名>”。继续安装会使用压缩包中的字体替换它。"`，图标 `arrow.triangle.2.circlepath`，按钮 `"替换"` / `"取消"`。
- 冲突在 **Plan 阶段**（拷贝之前）判定，结果存 `Plan.hasConflict`，供 UI 决定是否弹窗。

### 9.6 加密压缩包中的字体

入口文案 `"安装加密压缩包中的字体"`；先解锁 → 提取到受管理临时目录（`purpose = .fontInstallation`）→ 进入 9.4。

---

## 10. 安装 PKG（installer package）

### 10.1 定位【观测】

ArcZip **不执行** pkg 脚本，而是"安全准备后交给 macOS 安装器"：

- `"安全准备后交给 macOS 安装器"`、`"已交给 macOS 安装器"`、`"已打开安装器"`、`"正在读取安装信息…"`
- 关联设置说明：`"会替代系统"安装器"打开 PKG；ArcZip 仅预览和解压"`

### 10.2 流程

```
1. 校验选中项是 .pkg/.mpkg            → 失败："所选项目不是 macOS 安装包"/"当前文件不是 macOS 安装包"
2. 解出到 <tmp>/arczip-installer-<…>  → 失败："没有生成有效的 .pkg 安装包"/"<名> 是空的安装包"
3. 结构安全校验                        → "安装包包含根目录之外的项目："/"<名> 不是有效的扁平安装包"/"安装包路径无效"
4. NSWorkspace.open(pkgURL)            → 系统 Installer 接管（用户在此处看到系统授权 UI）
5. 结果："已交给 macOS 安装器"
```

- 缓存/清理沿用 `ManagedTemporaryArtifactRegistry`，崩溃后自清理。
- 为什么这样设计：pkg 的 `preinstall/postinstall` 是任意 root 脚本，App 自己跑等于绕过系统授权流程；交给 Installer 是**唯一合规**路径。

---

## 11. 解压缩链路（Extract All / Extract Selected / Quick Extract）

> 解压由 **XPC 服务**执行（`ArcZipArchiveService`），主程序只负责目标目录决策、冲突询问、完成后处理。以下 argv 取自该服务（保留符号信息，可读到方法名）。

### 11.1 三个入口，三套 argv【观测】

| 入口 | 符号（XPC） | 数组长度 | 差异 |
|---|---|---|---|
| 全部解压 | `SevenZipEngine.extractWholeArchive(_:to:password:progress:)` | 10 | `-aoa`（全部覆盖） |
| 解压所选 / 目录 | `SevenZipEngine.extractUsingCatalog(_:entries:authoritativeEntries:to:password:validatesDestination:selectionIsResolved:progress:)` | 11 | `-aos`（跳过已存在）+ `-scsUTF-8` |
| 应用包 | `SevenZipEngine.extractApplicationBundle(_:application:entries:to:password:progress:)` | 11 | `-aos` + `-scsUTF-8` |

共同前缀：

```
7zz x -bso0 -bsp1 -y <覆盖策略> -spd -snld10 -sccUTF-8 [-scsUTF-8] -o<目标目录> <密码参数> <压缩包路径> [<条目路径…>]
```

| 参数 | 含义 |
|---|---|
| `x` | 带完整路径解压（不是 `e`） |
| `-bso0` | 关闭常规输出（stdout 只留进度） |
| `-bsp1` | 进度输出到 stdout（供解析百分比） |
| `-y` | 全部询问自动 Yes（不交互） |
| `-aoa` / `-aos` | 覆盖全部 / 跳过已存在 |
| `-spd` | 关闭文件名通配符解释（条目名里的 `*`、`?` 按字面处理） |
| `-sccUTF-8` | 控制台 IO 字符集 UTF-8 |
| `-scsUTF-8` | **列表文件**字符集 UTF-8（仅"选择"类入口） |
| `-snld10` | 不公开但被 26.04 接受（实测有效；不要"修正"成 `-snl`） |
| `-o<dir>` | 输出目录，是**单个** argv 元素（`"-o" + path` 拼接） |
| `-p<pwd>` / `-p__ARCZIP_NO_PASSWORD__` | 密码；无密码时用哨兵常量（常量字符串本身已含 `-p`） |

**bsdtar 分支**：

```
/usr/bin/bsdtar x f -C <dest> --no-same-permissions --no-same-owner \
    --no-xattrs --null --files-from -        # 条目清单从 stdin 逐 NUL 读入
```

选择依据（强推断）：tar/tgz/tbz/txz 家族走 bsdtar（元数据语义更贴合 macOS）；7z/rar/zip/iso 等走 7zz；ZIP 另有原生实现用于创建与就地编辑。

### 11.2 进度与取消

- 进度：解析 `-bsp1` 的行（7zz 会输出 `\r` 刷新的百分比行），`SevenZipExtractionProgressEmitter` 归一化成 `(fraction, currentPath)`；`BSDTarProgressReporter` 对 tar 分支做同样的事。
- 取消：`ProcessCancellationController` + `ProcessTerminationWaiter` —— 先 `terminate()`，超时后 `SIGKILL`，并等待进程真正退出后才删除临时目录（避免"删了还在写"）。

### 11.3 内容过滤：三层，不是一个开关【观测】

1. **argv 层（粗）**：固定三项 `-xr!.DS_Store`、`-xr!__MACOSX`、`-xr!._*`（仅递归解压路径）。
2. **条目层（主判定）**：`ArchiveCore.ExtractionContentFilter.filteredEntries(_:policy:explicitlySelected:)`，`policy ∈ {preserveAll, excludingAuxiliaryEntries}`；**`explicitlySelected` 中的条目永远保留**。
3. **落地后兜底**：`AuxiliaryFileCleaner.cleanExtractedDirectory(at:preservingRelativePaths:)` 删除引擎仍可能创建的 `__MACOSX/`、`._*` 残留。

**辅助名名单（全部小写比较，所以 `Thumbs.db`/`THUMBS.DB` 都命中）：**

集合 A（11 项）：`.ds_store`、`.lsoverride`、`icon`+CR（macOS 自定义图标文件）、`thumbs.db`、`ehthumbs.db`、`desktop.ini`、`wpsettings.dat`、`zone.identifier`、`:zone.identifier`、`.volumeicon.icns`、`ehthumbs_vista.db`

集合 B（9 项）：`__macosx`、`.appledouble`、`.spotlight-v100`、`.trashes`、`.fseventsd`、`.temporaryitems`、`$recycle.bin`、`indexervolumeguide`、`.documentrevisions-v100`

单独：`system volume information`

前缀规则：`._*`（AppleDouble）用 `hasPrefix("._")` 判定，不在字符串名单里。

**为什么 `.gitignore` / `.env` 安全**：这是"名单制"而不是"点前缀/扩展名通配"，不在名单里就永不被过滤。**不要**改成 `hasPrefix(".")` 之类的规则。

**DMG 专用**：`settings.extraction.dmg.short` = `"过滤隐藏布局文件与 Applications 快捷方式"`；实现上 DMG 条目来自挂载目录枚举，`.DS_Store`/`.volumeicon.icns`/`.background` 命中名单，"Applications 替身"按"符号链接 + 链接目标 == /Applications"判定。

### 11.4 目标目录与命名冲突

| 入口 | 目标 |
|---|---|
| Quick Extract（双击 / Finder「快速解压到当前目录」） | 源压缩包所在目录 |
| Quick Extract to… | 用户选择目录 |
| 批量解压 | 当前目录 / 指定目录 |
| Open File Flow | 受管理临时目录（"解压单个文件到受管理的临时目录"） |

**命名冲突 → 新基名**：`ArchiveOutputFamily.collisionFreeBaseURL` —— **基名 + 空格 + 递增整数（从 1 开始）**，有扩展名时序号插在扩展名前（`Name 1.ext`）。

### 11.5 同名文件夹：Merge / Keep Both【观测】

- 只在"同名文件夹"层询问：标题 `"发现同名文件夹"`，正文 `"解压目标位置已有以下文件夹。"`，列表 `"同名文件夹"`。
- 语义（原文即规范）：`"合并会将内容加入现有文件夹，同名文件以编号保留；同时保留会创建带编号的新文件夹。"`
  - **合并**：解进已有文件夹；**文件夹内**同名文件改名保留（编号后缀），不覆盖。
  - **同时保留**：用 `collisionFreeBaseURL` 生成新文件夹后整体解进去。
- 引擎侧不改名：`-aoa` 只用于"无冲突/已确认覆盖"的全部解压，`-aos` 用于选择解压。
- 大小写/Unicode 归一化撞名在**预检**用 `collisionKey(for:caseSensitive:)` 检测，命中直接报错而不是覆盖。

### 11.6 密码

- 来源：用户输入（`"此压缩包受密码保护。"`、`"请输入“%@”的密码。%@"`）或 Finder/服务路径透传。
- 传给 7zz：`-p<password>`（argv 中可见 —— **这是一个真实的凭据暴露面**，复刻时建议改用 stdin 或临时密码文件）。
- 无密码时用哨兵 `-p__ARCZIP_NO_PASSWORD__`：配合 `-y` 与 `stdin = /dev/null`，保证加密包**立刻失败**而不是挂住等输入。
- "密码错误"与"文件损坏"靠**错误文本分类**区分（7-Zip 对每种情况有固定措辞）。
- 加密包里的单文件安装：先解到临时目录（`"正在准备应用程序"`、`"应用程序已从磁盘映像复制到临时目录"`）再进入安装流程。

### 11.7 完成后处理源压缩包【观测】

- `extraction.completedArchiveAction.v1` 三档：`每次均询问` / `始终保留文件` / `始终移入废纸篓`。
- 边界（原文）：`"仅在全部解压成功后处理原压缩包，默认每次均询问。"`；`"全部解压完成并保留压缩包后，自动关闭窗口"`；`"直接解压完成后，仅"始终移入废纸篓"会处理原包，其他选项均静默保留。"`
- 删除实现 = `FileManager.trashItem(at:resultingItemURL:error:)`（**进废纸篓**，可恢复）。
- Finder / 服务入口**不弹询问**，且多一层目标不可写处理（`services.destination_unwritable.*`）。

### 11.8 批量解压与拖出（drag-out）

- 批量：`finder.batch_extract_here` = `"将 %@ 个文件解压到当前目录"`；多入口共用同一 `ExtractionContentFilter`。
- 拖出：走 file promise（`FilePromiseTaskRegistry`、`ArchiveFilePromiseDelegate`），**逐条目按需解出**到临时文件再交付，过滤规则同样作用于"批量/文件夹拖出"（文案：`"批量解压或拖出文件夹时忽略隐藏项目、macOS 元数据和 Applications 替身"`）。

---

## 12. 状态机汇总（照此实现即可）

### 12.1 压缩包 → 安装应用

| # | 阶段 | 关键动作 | 失败文案 |
|---|---|---|---|
| 1 | 索引 | 打开时建索引（首层→全量） | `"无法创建浏览索引"` |
| 2 | 选中 app | 上下文判定 | `"所选项目不是 macOS 应用程序包"` |
| 3 | 授权 | Pro 检查 | `commercial.pro.feature_requires_pro` |
| 4 | 密码（如加密） | 解锁 | `"密码不正确"` / `"此压缩包需要密码"` |
| 5 | 预检 | 统计字节数、磁盘空间 | `"磁盘空间不足"` |
| 6 | 提取 | `extractApplicationBundle`（7zz `x -aos …`） | `"没有生成有效的 .app 应用程序包"` |
| 7 | 结构校验 | `Info.plist`/`APPL`/`CFBundleExecutable` | §7.3 表 |
| 8 | 签名分级 | Security.framework | 不阻断，转确认弹窗 |
| 9 | 用户确认 | 弹窗 | `"取消"` → 清理暂存退出 |
| 10 | 目标检查 | `/Applications` 可写性 | `"没有权限写入"应用程序"文件夹"` |
| 11 | 替换确认 | 同名询问 | `"替换现有应用？"` |
| 12 | 拷贝+元数据 | 同卷暂存 → move/replace + copyfile(xattr) | `"无法完成应用安装元数据："` |
| 13 | 去隔离 | `removexattr` | `"无法移除…的 com.apple.quarantine"` |
| 14 | 收尾 | 源包处理/关窗/打开 | `application.install.completion.trash_failed` |

### 12.2 DMG → 快速安装 / 打开

见 §8.7（12 个阶段表）。

### 12.3 字体安装

见 §9.4（8 步）。核心顺序：建目录 → `copyItem` 到 `.arczip-font-<UUID>` → 清 quarantine（resourceValues）→ `replaceItemAt`/`moveItem` → `CTFontManagerRegisterFontsForURL(scope=user)` → 清理暂存 → `"字体安装完成"`。

---

## 13. 复刻清单（按依赖顺序，可直接照着写）

> 目标：在**你自己的下载器**里复现"下载完成后按类型给一步到位操作"。以下按 ArcZip 的实际切分给出实现顺序，并标注哪些是"必须一致"，哪些是"可简化的实现选择"。

### 13.1 阶段 0：类型识别（必须低延迟）

```
detect(url) ->
  if isAppBundle(url):        .application      // Contents/Info.plist + CFBundlePackageType == APPL
  if ext ∈ {dmg,iso}:         .diskImage        // 进一步挂载后才能判断里面有什么
  if ext ∈ {otf,ttf,ttc}:     .font
  if ext ∈ {pkg,mpkg}:        .installerPackage
  if isArchive(url):          .archive(format)  // 需要索引才能判断里面有什么
  else:                       .plainFile
```
- **必须一致**：app 的判据是 `Info.plist` + `CFBundlePackageType`，而不是 `.app` 后缀。
- 可简化：容器内探测只做"根层"就够覆盖 90% 场景（ArcZip 也是先根层、再后台全量）。

### 13.2 阶段 1：动作模型（必须一致的部分）

```swift
struct ActionDescriptor {
    let id: String            // 稳定 ID，如 "install.application"
    let title: String         // 随上下文变化
    let help: String?
    let enabled: Bool
    let reason: String?       // 禁用原因（索引中/加密/需 Pro/不支持）
    let isPrimary: Bool
    let requiresPro: Bool
}
```
- **必须一致**：动作集合由上下文算出、有主/备之分、禁用要有原因文案。这三点决定了"智能感"。
- 可简化：ArcZip 用"轨道"UI；你用按钮组/菜单也能表达同样的语义。

### 13.3 阶段 2：提取/搬运层

| 来源 | 做法 | 要点 |
|---|---|---|
| 压缩包 | 外部 `7zz`/`bsdtar` → 临时目录 | `-aos` 跳过已存在、`-spd` 关通配、条目列表精确传入 |
| DMG | `hdiutil attach -readonly -nobrowse -noautoopen -puppetstrings -mountpoint <自建>` | 自己指定挂载点；解析 PTY 进度；`detach -force` 收尾 |
| 字体/普通文件 | 解到受管理临时目录 | 有所有权令牌，崩溃可清理 |

- **必须一致**：`-readonly` + 自建 `-mountpoint`（否则卷名冲突/中文卷名会咬人）；临时目录必须可自清理。
- 可简化：进度解析可从"每行解析"降级为"按字节数估算"。

### 13.4 阶段 3：安装执行器

**app**：结构校验 → 签名分级 → 同卷暂存 → `replaceItemAt`（有旧版）/ `moveItem`（无旧版）→ `removexattr(quarantine)`。
**字体**：扩展名白名单 → `CTFontManagerCreateFontDescriptorsFromURL` 验证 → copy 到暂存 → `replaceItemAt`/`moveItem` → `CTFontManagerRegisterFontsForURL(.user)`。
**pkg**：解出 → 路径穿越检查 → `NSWorkspace.open`（交给系统 Installer）。

- **必须一致**：同卷暂存 + 原子替换 + 替换失败可回滚；quarantine 在**最终路径**上清除。
- 可改进：字体注册失败时删除已落地文件（ArcZip 没做）。

### 13.5 阶段 4：安全与门控

- 风险分级（未签名/临时签名/未公证/来源不明）→ 二次确认，标题与正文按级替换。
- 特权组件（XPC/helper）校验调用方签名（`identifier + anchor apple generic + OU`）。
- Pro/授权门控：能力与授权解耦，UI 用徽标 + 说明，而不是隐藏功能。

### 13.6 阶段 5：收尾

- 源文件去留：保留 / 废纸篓 / 每次询问（默认询问）；**只在成功后**处理源文件。
- 失败不动源文件；临时物必清。
- 可选"自动关窗"只在"保留源文件"时启用（ArcZip 的原文规则）。

---

## 14. 复刻时最容易踩的坑（每条都对应 ArcZip 处理过的边界）

1. **同卷暂存**：跨卷 `rename` 退化为拷贝+删除，不原子、可能破签名。必须先在目标卷建隐藏暂存目录（`.arczip-install-` / `.arczip-font-` 前缀的做法）。
2. **不要直接在挂载卷里运行 app**：DMG 只读，卸载后路径失效。
3. **quarantine 清除要在最终路径**，且把 `ENOATTR`/`ENOENT` 当成功。
4. **符号链接/硬链接**：app bundle 内的链接必须保留（`copyfile` 递归处理时会保留；`FileManager.copyItem` 也保留）。
5. **DMG 卷名**：不要用 `/Volumes/<卷名>` 猜路径，自己 `-mountpoint`。
6. **外部挂载竞争**：轮询 + settle delay，不抢占。
7. **密码**：DMG 用 `-stdinpass`；解压器侧 ArcZip 用 `-p<pwd>`（**这是凭据暴露面**，复刻时建议改 stdin 或密码文件 + 立即清零缓冲）。
8. **索引未完成就允许动作**：会装到"还没解析完"的条目。用 `isReady/isIndexing` 禁用并给原因。
9. **重复点击**：任务登记表去重（ArcZip：`FlowTaskRegistry` + `runningFlowActionKinds`）。
10. **过滤范围**：只在"整体/批量"语义下过滤；显式选中的必须保留；app 包内部必须保留；**用名单制而不是点前缀通配**（否则会误杀 `.env`）。
11. **路径穿越**：拒绝 `../`（`"安装包包含根目录之外的项目："`、`"压缩包包含不安全路径："`）。
12. **冲突编号规则**：`基名 + 空格 + 序号`，扩展名前插入；大小写/Unicode 归一化撞名要在预检阶段就报错。
13. **卸载时机**：不要一装完就 `detach`（用户可能还要从卷里再装第二个 app）；ArcZip 用空闲宽限期回收。
14. **pkg 不要自己跑**：交给系统 Installer，否则等于绕过系统授权。

---

## 15. 证据附录

### 15.1 关键函数（arm64 主程序）

| 地址 | 作用 | 关键证据 |
|---|---|---|
| `0x1008e1544`…`0x1008e16d4` | 13 个 `FlowActionKind.rawValue` | 每函数字面量即 action id |
| `0x1008e9d9c` | 安装应用 / 打开映像 app / 打开已安装 app 的展示与标题切换 | `app.arczip.disk-image.application.prefers-open`、`…install.application`、`…open.disk-image-application`、`…open.installed-application`；`"安装到"应用程序"文件夹"`、`"交给 macOS 打开此应用"`、`"索引完成后即可安装"` |
| `0x1008e9494` | 字体 Flow 可用性（白名单判定） | `lastPathComponent`→`pathExtension`→`lowercased`→`Set.contains`；`"安装到当前用户的字体库"` |
| `0x1008e37ec` | 字体白名单第二份（`swift_once` 懒初始化，字面量 @`0x100becbd0`） | otf/ttf/ttc |
| `0x1008e9a2c` | Extract All | `"索引完成后即可全部解压"` |
| `0x1008eaa98` | Extract Selection | `flow.extract_selection.help` |
| `0x1008ea454` | Unavailable | `"ArcZip 不直接操作链接或特殊项目"`、`"不可直接操作"`、`"创建中的压缩包不能解压"` |
| `0x1008ea640` | PKG Flow | `"安全准备后交给 macOS 安装器"` |
| `0x1008e9710` / `0x1008f0488` | Open File Flow | `"解压到临时目录并使用系统默认应用打开"` |
| `0x1008f031c` | 打开格式白名单设置 | `"允许打开的文件格式"`、`openFile.allowedFormats.v1` |
| `0x1008ecd58` | 安装应用 Flow 设置描述 | `"从压缩包安装 macOS 应用"`、`"安装 App 时移除应用根目录已有的下载隔离标记"` |
| `0x1008f2270` | 字体白名单集合构造 | `Set(minimumCapacity:3)`，字面量 @`0x100bed818` |
| `0x1008f23d0` | 字体 Plan 构建（扩展名 + 目标 + 冲突） | `"所选项目不是字体文件"`、`"仅支持安装 OTF、TTF 和 TTC 字体"` |
| `0x1008f5918` | 字体真伪校验 | `CTFontManagerCreateFontDescriptorsFromURL` + `CFArrayGetCount>=1` |
| `0x1008f33b4`→`0x1008f4b3c` | 字体安装主链（8 段 async） | `copyItem`→清隔离→`replaceItemAt`/`moveItem` |
| `0x1008f2770`→`0x1008f3074` | 字体注册链 | `CTFontManagerRegisterFontsForURL(url, 2, &err)` |
| `0x1008f453c` | 字体冲突/落地 | `"字体库中已存在“"`、`replaceItemAt`、`moveItem` |
| `0x1008f3970` / `0x1008f3dd8` | 字体拷贝与暂存清理 | `.arczip-font-<UUID>` |
| `0x1008db52c` | 前置判定 | `"所选项目不是 macOS 应用程序包"` |
| `0x1008df62c` | app 结构校验 | `CFBundlePackageType`、`CFBundleExecutable`、三条错误 |
| `0x1008df4ec` | 去 quarantine | `removexattr(..., XATTR_NOFOLLOW)` |
| `0x1008dfdec` | 元数据拷贝 | 两次 `copyfile`（`0x000C0004` / `0x040C0004`）、`strerror` |
| `0x1008dd774` | 落位主流程（校验→权限→拷贝） | 调 `0x1008df62c`、`0x1008dfdec` |
| `0x1008dc8d4` | 目标已存在检测 | `"目标位置已存在“"` |
| `0x1008dcf3c` | 同卷暂存命名 | `.arczip-install-` |
| `0x100281718` / `0x10028199c` | 签名 requirement / 详细签名信息 | `SecRequirementCreateWithString`、`SecStaticCodeCheckValidity(WithErrors)`、`SecCodeCopySigningInformation` |
| `0x1000608f8` | DMG "直接打开"四类告警 | `disk_image.application.warning.*` |
| `0x10036eabc` / `0x10036f0d0` | 备选 Flow UI | `"另有 %lld 个备选 Flow"`、`"展开备选 Flow"` |
| `0x10026f650` | Pro 门控文案 | `commercial.pro.feature_requires_pro` |

### 15.2 关键函数（XPC `ArcZipArchiveService`，符号可读）

| 符号 | 作用 |
|---|---|
| `SevenZipEngine.extractWholeArchive(_:to:password:progress:)` | 全部解压（10 元素 argv，`-aoa`） |
| `SevenZipEngine.extractUsingCatalog(_:entries:authoritativeEntries:to:password:validatesDestination:selectionIsResolved:progress:)` | 选择解压（11 元素，`-aos` + `-scsUTF-8`） |
| `SevenZipEngine.extractApplicationBundle(_:application:entries:to:password:progress:)` | 应用包提取（11 元素） |
| `HDIUtilDiskImageMountDriver` / `HDIUtilProgressLineParser` | 挂载驱动与进度行解析 |
| `DiskImageMountProgressBroadcaster` / `DiskImageReadSessionProvider` | 进度广播 / 读会话 |
| `ProcessTerminationWaiter` / `ProcessCancellationController` | 子进程终止与等待 |
| `BSDTarProgressReporter` / `SevenZipExtractionProgressEmitter` | 两种引擎的进度归一化 |

### 15.3 已整理的命令行

```
# 挂载（主程序 Process，argv 顺序）
/usr/bin/hdiutil attach -plist -puppetstrings -readonly -nobrowse -noautoopen \
    -owners off -mountpoint <dir> [-noverify] [-stdinpass] <image>
# 密码：写入 stdin（password + "\n"），写完清零缓冲

# 卸载
/usr/bin/hdiutil detach -force <mountPath>     # 主路径
/usr/bin/hdiutil detach <mountPath>            # 非强制变体（另一构造点）

# 已挂载枚举
/usr/bin/hdiutil info -plist

# 解压（7zz，全部解压）
7zz x -bso0 -bsp1 -y -aoa -spd -snld10 -sccUTF-8 -o<dest> -p<pass|__ARCZIP_NO_PASSWORD__> <archive>

# 解压（7zz，选择解压/应用包）
7zz x -bso0 -bsp1 -y -aos -spd -snld10 -sccUTF-8 -scsUTF-8 -o<dest> -p<pass|哨兵> <archive> <entry…>

# 解压（bsdtar 分支）
/usr/bin/bsdtar x f -C <dest> --no-same-permissions --no-same-owner --no-xattrs --null --files-from -

# Security requirement（自身/XPC 互信）
anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
certificate leaf[subject.OU] = "<TEAMID>"
```

### 15.4 关键偏好键

```
applicationInstallation.quickInstall.v1
applicationInstallation.completedArchiveAction.v1
applicationInstallation.automaticallyClosesArchive.v1
openFile.allowedFormats.v1
extraction.completedArchiveAction.v1
extraction.automaticallyClosesArchive.v1
extraction.filtersSystemAuxiliaryFiles.v1
extraction.filtersDMGInstallerArtifacts.v1
extraction.extractsOnExternalOpen.v1
archiveOpening.prefersMiniWindow.v1
```

### 15.5 辅助文件名单（可直接照抄）

```
A(11): .ds_store .lsoverride icon<CR> thumbs.db ehthumbs.db desktop.ini
       wpsettings.dat zone.identifier :zone.identifier .volumeicon.icns ehthumbs_vista.db
B(9) : __macosx .appledouble .spotlight-v100 .trashes .fseventsd .temporaryitems
       $recycle.bin indexervolumeguide .documentrevisions-v100
单条 : system volume information
前缀 : ._*（AppleDouble）
```

### 15.6 本文的不确定性（保守清单）

- 签名四分类的**精确判定顺序**：观测到 API + 四组文案，未观测到分类函数体（§7.4 已标"推断"）。
- `copyfile` 第二次调用的高位标志语义（`0x04000000`）：需按 macOS SDK 版本核对 `copyfile.h`。
- 字体"用户取消"的最终表现（静默结束 vs 显示"字体库中已存在"）。
- `~/Library/Fonts` 在**沙盒**环境下不可写：ArcZip 未做特殊处理（推断靠 `CocoaError` 映射）。
- 解压密码是否始终经由 argv（代码中可见 `-p<密码>` 的拼接，但未做运行时 `ps` 验证）。
- 挂载轮询间隔/settle delay 的具体数值、`Phase` 枚举的完整取值。
- DMG 扫描的层次上限（"根层 + 一层"还是"根层 + N 层"）。
- 应用安装完成后是否立即触发 DMG 卸载（未定位触发点；ArcZip 有空闲回收机制）。

---

*文档结束。所有"观测"项均可在 `ArcZip-1.1.5-273.dmg` 内用 `strings`、`plutil -convert`、`nm`、`otool -l` 等系统自带工具复核。*
