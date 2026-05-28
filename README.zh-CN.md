# AI Coding Proxy

[English](README.md)

这是一个 Swift monorepo，提供本地 Coding AI 账号代理服务和 macOS 桌面控制应用。

## 构建目标

- `CodexProxyCore`: 账号存储、OAuth/Token 刷新、用量拉取、代理协议转换、统计聚合。
- `CodexProxyDeploy`: 基于 SSH/PTy 的远程部署与 systemd 控制辅助能力。
- `codex-proxyd`: 守护进程入口。
- `CodexProxyDesktop`: macOS SwiftUI 仪表盘。

## 目录结构

- `Sources/CodexProxyCore`
- `Sources/CodexProxyDeploy`
- `Sources/CodexProxyDaemon`
- `Sources/CodexProxyDesktop`
- `Tests/CodexProxyCoreTests`
- `.github/workflows/release.yml`

## 本地开发

```bash
swift build
swift run codex-proxyd serve --data-dir ~/Library/Application\\ Support/CodexProxy
```

## 支持的认证来源

- 从桌面应用导入 ChatGPT OAuth。
- 当 `~/.codex/auth.json` 中包含 ChatGPT token 时，从该文件导入。
- 当 `~/.codex/auth.json` 中包含 `OPENAI_API_KEY` 时，从该文件导入。
- 从导出的备份中导入单个或批量 JSON。

## 本地守护进程行为

- 桌面应用会控制一个独立的 `codex-proxyd` 进程。
- 关闭主窗口只会隐藏应用，不会停止守护进程。
- `auto_start = true` 会写入带有 `RunAtLoad` 和 `KeepAlive` 的 LaunchAgent plist。
- `auto_start = false` 会保留磁盘上的 LaunchAgent 文件，但会 `bootout` 已运行的本地守护进程，并关闭 `RunAtLoad` / `KeepAlive`。
- 桌面应用里的代理设置会应用到守护进程的出站流量。

## macOS 打包

构建一个包含守护进程的可运行 `.app` 包：

```bash
chmod +x Scripts/prepare-swift-static-linux-sdk.sh Scripts/build-linux-artifacts.sh Scripts/build-macos-app.sh Scripts/package-release.sh Scripts/package-local-release.sh
./Scripts/prepare-swift-static-linux-sdk.sh
./Scripts/build-macos-app.sh
```

创建支持远程部署能力的 zip 发布包：

```bash
./Scripts/package-release.sh
```

在打包前强制刷新打包内置的 `mihomo` 缓存：

```bash
./Scripts/package-release.sh --force-refresh
```

创建一个更小的、仅本地使用的 zip 发布包，不包含 `Contents/Resources/RemoteArtifacts/`：

```bash
./Scripts/package-local-release.sh
```

本机快速验证时，可以只构建当前 Mac 架构并跳过 appcast：

```bash
./Scripts/package-local-release.sh --host-only
```

只刷新 macOS 的 `mihomo` 缓存，并保持仅本地打包流程不触发 Linux SDK 准备：

```bash
./Scripts/package-local-release.sh --force-refresh
```

直接运行 `build-macos-app.sh` 时，产物仍会输出到 `Dist/`：

- `Dist/AI Coding Proxy.app`
- `Dist/codex-proxyd-macos`
- `Dist/mihomo-macos`

`package-release.sh` 会将支持远程部署的发布产物输出到 `Dist/remote-capable/`：

- `Dist/remote-capable/AI Coding Proxy.app`
- `Dist/remote-capable/codex-proxyd-macos`
- `Dist/remote-capable/mihomo-macos`
- `Dist/remote-capable/AICodingProxy-macos-arm64-<version>.zip`
- `Dist/remote-capable/AICodingProxy-macos-x86_64-<version>.zip`

`package-release.sh` 还会在多次运行之间复用 `Artifacts/` 作为默认的 Linux 部署包缓存，因此重复构建发布包时，除非显式传入 `--force-refresh`，否则不会重复下载 `mihomo`。

`package-local-release.sh` 会将仅本地使用的发布产物输出到 `Dist/local-only/`：

- `Dist/local-only/AI Coding Proxy.app`
- `Dist/local-only/codex-proxyd-macos`
- `Dist/local-only/mihomo-macos`
- `Dist/local-only/AICodingProxy-macos-arm64-<version>-local.zip`
- `Dist/local-only/AICodingProxy-macos-x86_64-<version>-local.zip`

`package-local-release.sh` 会跳过 Static Linux SDK 准备步骤，并且仅在显式传入 `--force-refresh` 时刷新 macOS 的 `mihomo` 缓存。它支持 `--arch host|arm64|x86_64|all`；默认 `all` 保持双架构发布产物和 appcast 不变，`--host-only` 是本地验证用的单架构快速路径。

本地打包还会默认复用 `.build/codex-proxy-build-cache/` 下的脚本构建缓存。可以用 `CODEX_PROXY_BUILD_CACHE_DIR` 改缓存目录，用 `CODEX_PROXY_REBUILD_MLX_OCR_HELPER=1` 强制重建缓存的 Local MLX OCR helper，用 `CODEX_PROXY_REBUILD_APP_ICON=1` 强制重新渲染 AppIcon。`--force-refresh` 仍只用于刷新 `mihomo` 这类外部下载/打包资源。

如果直接通过 `Scripts/build-macos-app.sh` 构建，不带后缀的 `Dist/AI Coding Proxy.app`、`Dist/codex-proxyd-macos` 和 `Dist/mihomo-macos` 仍然是当前机器对应架构的原生输出。

## macOS 安装与运行

启动打包后的桌面应用：

```bash
open "Dist/AI Coding Proxy.app"
```

应用会在首次启动时安装或更新本地 LaunchAgent，之后通过仪表盘管理守护进程：

- `Overview` 和 `Settings` 会展示 LaunchAgent 注册状态、运行状态、最近一次启动错误以及本地日志路径。
- 关闭窗口只会隐藏应用；守护进程会继续提供服务，直到你显式停止它。
- 在直接执行 `build-macos-app.sh` 后，也可以手动启动 `Dist/codex-proxyd-macos` 进行诊断。
- `Dist/remote-capable/codex-proxyd-macos` 和 `Dist/local-only/codex-proxyd-macos` 分别对应两种发布脚本打包出来的守护进程二进制。
- 支持远程部署的打包应用会在 `Contents/Resources/RemoteArtifacts/` 下内置 `linux-amd64` 和 `linux-arm64` 部署包。
- 仅本地打包的应用会有意省略 `Contents/Resources/RemoteArtifacts/`，因此 `Deploy` / `重新部署` 操作不可用；但 `Remote` 页面仍可加载状态、查看日志，并管理已经部署好的主机。

## 路径与日志

macOS 下默认的本地路径：

- 数据目录：`~/Library/Application Support/CodexProxy`
- SQLite 数据库：`~/Library/Application Support/CodexProxy/codex-proxy.sqlite3`
- 桌面端偏好设置：`~/Library/Application Support/CodexProxy/desktop-preferences.json`
- LaunchAgent plist：`~/Library/LaunchAgents/io.shiguanghuxian.codex-proxy.plist`
- 守护进程标准输出日志：`~/Library/Application Support/CodexProxy/daemon.out.log`
- 守护进程标准错误日志：`~/Library/Application Support/CodexProxy/daemon.err.log`

常用本地诊断命令：

```bash
launchctl print "gui/$(id -u)/io.shiguanghuxian.codex-proxy"
tail -n 80 ~/Library/Application\ Support/CodexProxy/daemon.err.log
tail -n 80 ~/Library/Application\ Support/CodexProxy/daemon.out.log
```

## 升级与卸载

升级流程：

- 用更新后的直接构建产物替换 `Dist/AI Coding Proxy.app`，或者解压 `Dist/remote-capable/` / `Dist/local-only/` 中对应的压缩包。
- 启动新应用一次；如果守护进程路径、主机或端口发生变化，它会重写 LaunchAgent plist。
- 如果你关闭了 `auto_start`，桌面应用会执行 `bootout` 停止守护进程，但保留 plist 作为“已安装但已禁用”的服务定义。

卸载本地服务状态：

```bash
launchctl bootout "gui/$(id -u)/io.shiguanghuxian.codex-proxy" || true
rm -f ~/Library/LaunchAgents/io.shiguanghuxian.codex-proxy.plist
rm -rf ~/Library/Application\ Support/CodexProxy
```

## Linux 部署包

内置的远程部署包会在 macOS 上借助固定版本的 Swift.org toolchain 和 Swift Static Linux SDK 构建，不再依赖 Docker。

```bash
./Scripts/prepare-swift-static-linux-sdk.sh
./Scripts/build-linux-artifacts.sh
```

为两份 Linux 构建产物都强制刷新一次 `mihomo` 下载：

```bash
./Scripts/build-linux-artifacts.sh --force-refresh
```

准备脚本会校验固定版本的 Swift toolchain、按需安装匹配的 Static Linux SDK，并让本地构建与 CI / 发布打包保持一致。

该脚本会输出：

- `Artifacts/linux-amd64/codex-proxyd`
- `Artifacts/linux-amd64/mihomo`
- `Artifacts/linux-arm64/codex-proxyd`
- `Artifacts/linux-arm64/mihomo`

下载到的 `mihomo` 二进制会按目标平台和架构缓存在 `ThirdParty/mihomo/` 下；你也可以通过 `Scripts/fetch-mihomo.sh --force-refresh [dest_dir] [arch] [platform]` 显式刷新某一个缓存项，再复制到目标输出目录。

`Scripts/build-macos-app.sh` 默认使用支持远程部署的 `full` profile，并会把两套完整部署包都复制进 app bundle，因此 `Remote` 页面可以直接从应用内完成部署或重新部署，而无需在部署时再下载、使用 Docker，或重新本地构建。

当你只需要本地 macOS 运行产物，并希望省略内置的 Linux 部署包时，可以把 `local-only` 作为第四个参数传给脚本，或者直接使用 `Scripts/package-local-release.sh`。该 profile 仍然支持查看远程状态、日志以及管理已部署服务，但会禁用应用内远程部署与重新部署能力。
