---
name: cooldm-bump-version
description: 升级酷的下载管理器的项目版本号；用户说“版本号+1”“第二段+1”或准备新版本时使用。同步 VERSION 与 BUILD_NUMBER，核对历史标签、打包元数据和 GitHub Actions 发布约束。
---

# 升级项目版本

从仓库根目录执行命令。只要求创建、修改本技能时，不顺带升级当前版本。

## 递增规则

产品版本固定为 `主版本.次版本.修订版本`，三段均为非负整数：

| 用户要求 | 规则 | 示例 |
| --- | --- | --- |
| “版本号+1”、未指定段数、第三段+1 | 第三段加一 | `1.2.9 → 1.2.10` |
| 第二段+1、次版本+1 | 第二段加一，第三段归零 | `1.2.9 → 1.3.0` |
| 第一段+1、主版本+1 | 第一段加一，第二、三段归零 | `1.2.9 → 2.0.0` |

第三段不按十进制位数进位。用户明确指定目标版本时遵循该值，但仍须验证三段格式、版本递增、标签未占用和构建号单调递增；不要用另一次默认加一覆盖明确目标。

`BUILD_NUMBER` 独立于产品版本，不通过拼接三段计算。取当前构建号与全部历史 `v*` 标签构建号中的最大值，再加一；正常情况下就是当前值加一。

## 文件与现有发布链

每次执行前核对以下源文件；若发布约束已有变化，先按当前代码修正本技能的操作：

- [VERSION](../../../VERSION)：用户可见的三段式版本，必须修改。
- [BUILD_NUMBER](../../../BUILD_NUMBER)：Sparkle 比较更新顺序的纯数字构建号，必须同步修改。
- [发布工作流](../../../.github/workflows/release-macos.yml) 与 [发布脚本](../../../scripts/publish-macos.sh)：标签、输入参数、历史构建号和发布前置检查的依据。
- [打包脚本](../../../scripts/package-macos.sh) 与 [发布说明](../../../docs/macos-release.md)：发行包验证的依据。

`packaging/macos/Info.plist` 是模板。打包脚本复制后，根据两个根版本文件写入并校验 `CFBundleShortVersionString` 和 `CFBundleVersion`；模板中的旧默认值不要求手工跟随升级。应用的关于窗口与更新控制器读取 bundle 元数据。

不全局替换旧版本字符串；历史 CHANGELOG、文档示例、依赖版本、Core Data schema 和浏览器协议版本各自独立。若用户同时要求更新发行说明，只记录本次真实改动。

## 执行

1. 检查 `git status --short` 与两个版本文件的现有差异，保留已有修改。若同一次请求已完成递增，核验结果即可，不因重试、恢复上下文或执行 `--check` 再加一次。
2. 核对 `origin` 是当前 fork 的发布仓库，运行 `git fetch origin --tags` 刷新全部历史标签，不加 `--force` 或 `--prune`。若获取失败或存在标签冲突，停止版本写入，说明历史核验未完成；不能用过期的本地标签声称已排除 CI 版本冲突。
3. 使用 [递增脚本](scripts/bump_version.py)。它只读本地 Git 标签，故不能省略上一步。默认修改两个根版本文件；`--dry-run` 只预览，`--check` 只核验当前文件。

```sh
# 默认第三段加一
python3 .agents/skills/cooldm-bump-version/scripts/bump_version.py

# 用户指定第二段或第一段加一时，分别使用 --part 2 或 --part 1
python3 .agents/skills/cooldm-bump-version/scripts/bump_version.py --part 2

# 预览或只核验；不会写入版本文件
python3 .agents/skills/cooldm-bump-version/scripts/bump_version.py --dry-run
python3 .agents/skills/cooldm-bump-version/scripts/bump_version.py --check
```

`--check` 用于本次发布标签尚未创建的准备阶段；标签创建后，按下节核对已提交文件与标签指向，不再把本次标签当作可复用的空位。

脚本在写入前拒绝无效格式和已占用的新标签，并扫描全部 `v*` 标签中的有效构建号，与发布脚本的历史范围一致；旧上游标签没有 `BUILD_NUMBER` 时忽略。不要为绕过检查而移动旧标签或降低构建号。

## 验证与 GitHub Actions 交接

修改后运行 `--check` 和 `git diff --check`，审阅两个版本文件的差异。按项目现有发布要求，使用完整 Xcode 实际打包；不使用 `--skip-build` 或 `CDM_VERSION` / `CDM_BUILD_NUMBER` 覆盖值掩盖源文件问题：

```sh
env -u CDM_VERSION -u CDM_BUILD_NUMBER ./scripts/package-macos.sh --zip --dmg
```

脚本会检查生成 `.app` 的两项版本值并验证代码签名。再检查 ZIP 内 `Info.plist` 的版本、DMG 的完整性与只读挂载后的应用版本、签名，均应与根文件一致。缺少 Xcode、`create-dmg` 或打包失败时，保留已完成的版本修改，明确报告未完成的验证，不能声称已可发布。纯版本改动不额外运行整套 Swift 功能测试。

在用户另外授权提交、打标签或发布时，才执行相应动作，并检查：

- 两个版本文件都进入同一发布提交；工作树干净。发布脚本会拒绝含未跟踪文件的脏工作树。
- 新标签严格为 `v` 加 `VERSION`，指向包含上述文件的发布提交，并已推到远端；不能只修改工作区后给旧提交打标签。
- 新 `BUILD_NUMBER` 严格大于所有其他 `v*` 标签中可读的有效构建号。提交和发布间若新增了标签，要刷新历史并重新检查。
- tag 推送会触发工作流。手工运行必须填写已经存在的 `release_tag`；`version` 与 `build_number` 通常留空以读取 tag/源文件，填写时必须完全一致。
- 目标 GitHub Release 尚未存在。工作流检出目标 tag，`--publish` 要求 tag 指向 HEAD，且禁止 `--skip-build`，不会覆盖旧 Release。

版本预检和本地打包通过，只证明检查到的版本约束和产物符合要求。GitHub Actions 的 Xcode runner、签名 Secret、权限和网络仍须以真实运行结果为准；不为检查版本而运行带 `--publish` 的发布脚本。

交付时给出产品版本与构建号的前后值、修改文件、实际执行的验证及未完成项；不要把“升级版本”自动扩展为提交、推送或发布。
