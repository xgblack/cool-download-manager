# macOS 发布与更新

本项目的 macOS 更新链使用 Sparkle 2.9.6。应用本体和 Sparkle 组件使用 ad-hoc Apple Code Signing，更新 ZIP 和 appcast 使用 Sparkle Ed25519 签名。发行物固定为 Apple Silicon（arm64），不支持 Intel Mac。Sparkle 及其依赖的版权和许可文本会复制到应用包的 `Contents/Resources/Licenses`。由于当前没有 Developer ID，发布包不是经过 Apple 公证的安装包；手工 DMG 始终保留，作为更新失败或用户不接受自动更新时的回退路径。

## 版本约定

- `VERSION` 是用户可见的产品版本，固定使用三个数字组成的 `主版本.次版本.修订版本`。
- `BUILD_NUMBER` 是只增不减的纯数字，写入 `CFBundleVersion`。Sparkle 使用它判断更新顺序，因此即使产品版本不变，构建号也不能回退。
- `CFBundleShortVersionString` 使用 `VERSION`；`CFBundleVersion` 使用 `BUILD_NUMBER`。
- Git tag 使用 `v<产品版本>`，例如 `VERSION=1.0.5` 对应 `v1.0.5`。同一个 tag 和同一个发布资产不覆盖重用。
- 当前稳定 feed 不发布 beta/RC。若以后需要预发布，应增加独立 Sparkle channel 和独立 feed，不能让 GitHub `latest` 把预发布推送给稳定用户。
- Core Data schema、REST API 和 Native Messaging 协议版本独立维护，不用应用构建号代替。

发布前至少执行：

```sh
printf '1.0.5\n' > VERSION
printf '1005\n' > BUILD_NUMBER
git add VERSION BUILD_NUMBER
git commit -m "chore(release): prepare v1.0.5"
git tag -a v1.0.5 -m "酷的下载管理器 v1.0.5"
```

实际写入版本文件时请使用 `apply_patch` 或编辑器；上面的命令只展示值和 tag 约定。

## 密钥

Sparkle 的 Ed25519 私钥只存放在开发机钥匙串或 CI Secret，不进入 Git、app 包、appcast、日志和命令行参数。首次配置可在依赖构建完成后运行：

```sh
.build/XcodePackageData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

把工具输出的公钥写入 `packaging/macos/Info.plist` 的 `SUPublicEDKey`。当前仓库已经写入对应公钥；不要把 `generate_keys -x` 导出的私钥文件提交到仓库。CI 使用名为 `SPARKLE_ED25519_PRIVATE_KEY` 的 GitHub Actions Secret，发布脚本只通过标准输入传给 `generate_appcast --ed-key-file -`。

如果更换 Ed25519 密钥，不能直接从新版本删除旧 key。应按 Sparkle 的 key rotation 流程发布包含新公钥的过渡版本，并确保过渡版本仍能被旧版本验证；密钥轮换前先在隔离的测试 Release 验证。

## 应用行为

打包应用启动后，`SPUStandardUpdaterController` 读取 `Info.plist`：

- `SUEnableAutomaticChecks=true`，默认每 24 小时检查一次。
- `SUAutomaticallyUpdate=true`，允许 Sparkle 在后台下载并在合适的退出/重启时机安装。
- `SURequireSignedFeed=true` 与 `SUVerifyUpdateBeforeExtraction=true`，要求签名 appcast，并在解压前验证更新归档。
- 菜单“检查更新”调用 Sparkle 的标准交互界面，负责版本比较、下载、验签、安装和重启；不再请求 GitHub REST API。

SwiftPM/Xcode 的开发运行没有发布 `Info.plist` 中的 `SUFeedURL`，因此不会启动 updater，也不会把开发构建误当成可更新版本。

自动检查只发生在应用运行期间；本方案不创建 LaunchAgent、登录项或常驻后台服务。用户退出应用后不会由独立进程唤醒检查，下一次启动时 Sparkle 会根据自己的检查间隔决定是否检查。

历史上没有集成 Sparkle 的版本无法凭空获得 updater。首次升级必须让用户先通过手工 DMG 安装一个带 Sparkle 的版本，之后才能使用应用内的自动检查和自动安装。

## 资产和托管

资产托管在 GitHub Releases（当前仓库为 `xgblack/cool-download-manager`）：

| 资产 | 用途 |
| --- | --- |
| `CoolDownloadManager-macOS-arm64.zip` | Sparkle enclosure，包含完整 `.app`，必须有 `sparkle:edSignature` |
| `CoolDownloadManager-macOS-arm64.dmg` | 用户手工下载、挂载并拖到“应用程序” |
| `appcast.xml` | Ed25519 签名的更新 feed |

应用内 feed 使用稳定地址：

```text
https://github.com/xgblack/cool-download-manager/releases/latest/download/appcast.xml
```

appcast 的 enclosure 使用不可变的 tag 地址，例如：

```text
https://github.com/xgblack/cool-download-manager/releases/download/v1.0.5/CoolDownloadManager-macOS-arm64.zip
```

DMG 不放入 appcast，因为它是人工拖拽安装介质；Sparkle 只消费 ZIP。稳定 appcast 每次只保留当前 Release 的一个 arm64 enclosure，旧版本的 ZIP/DMG 保留在各自不可变的 GitHub Release 中，但不合并进更新 feed。若未来改用其他托管，只需同步修改 `Info.plist`、发布脚本和 CI，不要让应用动态拼接下载 URL。

## 本地构建和发布

只构建本地资产，不上传：

```sh
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" \
  ./scripts/package-macos.sh --zip --dmg
```

生成 appcast 并使用钥匙串中 `ed25519` 账户签名：

```sh
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" \
  ./scripts/publish-macos.sh
```

在 CI 或没有可交互钥匙串的环境中，注入 Secret（脚本不会打印 Secret）：

```sh
SPARKLE_ED25519_PRIVATE_KEY="$PRIVATE_KEY_SECRET" \
  ./scripts/publish-macos.sh --version 1.0.5 --build-number 1005
```

只有明确需要上传时才加 `--publish`。脚本的上传顺序固定为：

1. 构建并测试。
2. ad-hoc 签名 `.app`，生成 ZIP 和手工 DMG。
3. 对 ZIP 生成 enclosure Ed25519 签名，并生成签名 appcast。
4. 创建 draft GitHub Release。
5. 上传 ZIP 和 DMG。
6. 最后上传 `appcast.xml`，再把 Release 从 draft 发布。

`--publish` 要求本地和远端都已经存在对应 tag，并拒绝覆盖已有 Release；脚本传给 `gh release create` 的 `--verify-tag` 会阻止 GitHub 从默认分支偷偷创建 tag。发布完成时显式设置该 Release 为 Latest，确保稳定 `latest/download/appcast.xml` 指向刚发布的 feed。上传失败时 Release 保持 draft，稳定 URL 不会提前指向不完整资产。发布模式禁止 `--skip-build`，避免把旧的 Xcode 产物发布到新 tag。

`--publish` 还要求 tag 指向当前 `HEAD`，提交后的 `VERSION`/`BUILD_NUMBER` 与发布参数一致，且
`BUILD_NUMBER` 大于所有带有构建号的历史 `v*` tag。构建号输入不是 CI 生成的临时值；若通过
workflow 手工填写，必须与 tag 中提交的 `BUILD_NUMBER` 文件相同。

发布门禁还包括：工作树必须干净、tag 必须解析到当前 `HEAD`、tag 必须严格匹配
`v<version>`，并且目标 GitHub Release 不能已经存在。脚本会先在本地完成构建、DMG、ZIP
签名和 appcast 验签，再创建 draft；不会用 `--clobber` 覆盖历史资产。发布后发现问题时，
不要移动或重用旧 tag，也不要覆盖历史 Release；Sparkle 的版本比较不会可靠地把用户降级。
当前回滚方式是提交修复并发布更高的产品版本和构建号（例如 `1.0.6/1006`）。

## CI 自动发布

`.github/workflows/release-macos.yml` 在推送 `v*` tag 或手工触发时运行，要求：

- runner 提供 Xcode 27 和 macOS 27 SDK；
- 仓库 Secret `SPARKLE_ED25519_PRIVATE_KEY` 与 `SUPublicEDKey` 匹配；
- workflow 具有 `contents: write` 权限；
- 测试、包签名、appcast 签名和包结构验证全部成功后才上传 Release。

手工触发时必须在 `release_tag` 输入中选择已经推送的 `v<version>` tag；workflow 会检出该
tag，而不是使用触发页面所在的分支。`version`（如填写）必须与 tag 去掉 `v` 后的值完全一致，
否则直接失败。推送新版本时，建议使用 tag 事件触发，避免从未提交的分支发布。

首次正式发布前必须先创建一个私有/草稿测试 Release，验证从旧 ad-hoc 包到新 ad-hoc 包的下载、验签、退出安装和重启。没有成功发布至少一个包含 `appcast.xml` 的 Release 前，不能宣称线上自动更新已可用。

## 验证清单

本地发行包至少检查：

```sh
plutil -lint "dist/酷的下载管理器.app/Contents/Info.plist"
codesign --verify --deep --strict "dist/酷的下载管理器.app"
otool -L "dist/酷的下载管理器.app/Contents/MacOS/CoolDownloadManager"
xmllint --noout "dist/appcast.xml"
grep -F 'sparkle:edSignature=' "dist/appcast.xml"
grep -F '<!-- sparkle-signatures:' "dist/appcast.xml"
```

测试场景应覆盖：无新版本、签名 feed 被篡改、ZIP 签名被篡改、下载失败、旧 ad-hoc 包升级到新包、手工 DMG 安装回退。源码和本地包验证不能替代真实 GitHub Release、安装目录权限、退出重启和 Gatekeeper 行为验收。

也可以直接用 Sparkle 工具验签 ZIP 和 feed（下面的 `sign_update` 路径按本机依赖位置调整）：

```sh
SIGN_UPDATE=".build/XcodePackageData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
ZIP="dist/CoolDownloadManager-macOS-arm64.zip"
SIG="$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' dist/appcast.xml)"
"$SIGN_UPDATE" --verify "$ZIP" "$SIG"
"$SIGN_UPDATE" --verify dist/appcast.xml
```

`--verify` 失败时应停止发布，不要把只通过 XML 语法检查的 feed 当成已签名 feed。

发行脚本固定生成 arm64 ZIP、DMG 和单条 appcast，不接受架构参数，避免同一 Release 出现不匹配的更新资产。

## ad-hoc 的边界

ad-hoc 签名能让 Sparkle 比较并验证同一更新密钥链上的包，但不提供 Developer ID 身份信誉或 Apple 公证。用户从网络下载 DMG/ZIP 时仍可能看到 Gatekeeper 警告；这不是 Sparkle 签名失败。当前产品应在发行说明中明确这一点，并把手工 DMG 作为可见回退。ad-hoc 包不启用 hardened runtime：它没有 Team ID，若开启 library validation，主程序会拒绝加载同样 ad-hoc 签名的 Sparkle framework。获得 Developer ID 后，可在不改变 Sparkle Ed25519 feed 的前提下，把 `CDM_SIGNING_IDENTITY` 切换为 Developer ID，重新签名所有嵌套组件并增加公证/Staple 步骤。
