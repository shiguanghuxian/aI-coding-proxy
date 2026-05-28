# AI Coding Proxy

[中文说明](README.zh-CN.md)

Swift monorepo for a local coding AI account proxy service and macOS desktop control app.

## Targets

- `CodexProxyCore`: account storage, OAuth/token refresh, usage fetch, proxy translation, stats aggregation.
- `CodexProxyDeploy`: SSH/PTy remote deploy and systemd control helpers.
- `codex-proxyd`: daemon entrypoint.
- `CodexProxyDesktop`: macOS SwiftUI dashboard.

## Layout

- `Sources/CodexProxyCore`
- `Sources/CodexProxyDeploy`
- `Sources/CodexProxyDaemon`
- `Sources/CodexProxyDesktop`
- `Tests/CodexProxyCoreTests`
- `.github/workflows/release.yml`

## Local Development

```bash
swift build
swift run codex-proxyd serve --data-dir ~/Library/Application\\ Support/CodexProxy
```

## Supported Auth Sources

- ChatGPT OAuth import from the desktop app.
- `~/.codex/auth.json` import when it contains ChatGPT tokens.
- `~/.codex/auth.json` import when it contains `OPENAI_API_KEY`.
- Single or batch JSON import from exported backups.

## Local Daemon Behavior

- The desktop app controls a separate `codex-proxyd` process.
- Closing the main window hides the app instead of stopping the daemon.
- `auto_start = true` writes a LaunchAgent plist with `RunAtLoad` and `KeepAlive`.
- `auto_start = false` keeps the LaunchAgent file on disk but boots out any running local daemon and disables `RunAtLoad` / `KeepAlive`.
- Proxy settings from the desktop app are applied to daemon outbound traffic.

## macOS Packaging

Build a runnable `.app` bundle with the bundled daemon:

```bash
chmod +x Scripts/prepare-swift-static-linux-sdk.sh Scripts/build-linux-artifacts.sh Scripts/build-macos-app.sh Scripts/package-release.sh Scripts/package-local-release.sh
./Scripts/prepare-swift-static-linux-sdk.sh
./Scripts/build-macos-app.sh
```

Create a remote-capable zip release archive:

```bash
./Scripts/package-release.sh
```

Rebuild bundled `mihomo` caches before packaging:

```bash
./Scripts/package-release.sh --force-refresh
```

Create a smaller local-only zip release archive without `Contents/Resources/RemoteArtifacts/`:

```bash
./Scripts/package-local-release.sh
```

For faster local testing, build only the current Mac architecture and skip the appcast:

```bash
./Scripts/package-local-release.sh --host-only
```

Refresh only the macOS `mihomo` caches while keeping the local-only flow free of Linux SDK preparation:

```bash
./Scripts/package-local-release.sh --force-refresh
```

Direct `build-macos-app.sh` output is still written to `Dist/`:

- `Dist/AI Coding Proxy.app`
- `Dist/codex-proxyd-macos`
- `Dist/mihomo-macos`

`package-release.sh` writes remote-capable distribution artifacts to `Dist/remote-capable/`:

- `Dist/remote-capable/AI Coding Proxy.app`
- `Dist/remote-capable/codex-proxyd-macos`
- `Dist/remote-capable/mihomo-macos`
- `Dist/remote-capable/AICodingProxy-macos-arm64-<version>.zip`
- `Dist/remote-capable/AICodingProxy-macos-x86_64-<version>.zip`

`package-release.sh` also reuses `Artifacts/` as the default bundled Linux deployment package cache across runs, so repeat release builds avoid re-downloading `mihomo` unless you pass `--force-refresh`.

`package-local-release.sh` writes local-only distribution artifacts to `Dist/local-only/`:

- `Dist/local-only/AI Coding Proxy.app`
- `Dist/local-only/codex-proxyd-macos`
- `Dist/local-only/mihomo-macos`
- `Dist/local-only/AICodingProxy-macos-arm64-<version>-local.zip`
- `Dist/local-only/AICodingProxy-macos-x86_64-<version>-local.zip`

`package-local-release.sh` skips Static Linux SDK preparation and only refreshes macOS `mihomo` caches when you explicitly pass `--force-refresh`. It supports `--arch host|arm64|x86_64|all`; the default `all` preserves the two-architecture release output and appcast, while `--host-only` is the quick single-architecture path for local verification.

Local packaging also reuses script build caches under `.build/codex-proxy-build-cache/` by default. Set `CODEX_PROXY_BUILD_CACHE_DIR` to move that cache, `CODEX_PROXY_REBUILD_MLX_OCR_HELPER=1` to rebuild the cached Local MLX OCR helper, or `CODEX_PROXY_REBUILD_APP_ICON=1` to force AppIcon rendering. `--force-refresh` remains reserved for external downloaded/bundled assets such as `mihomo`.

When built directly with `Scripts/build-macos-app.sh`, the unsuffixed `Dist/AI Coding Proxy.app`, `Dist/codex-proxyd-macos`, and `Dist/mihomo-macos` remain the host-native outputs for the current machine.

## macOS Install And Run

Launch the packaged desktop app:

```bash
open "Dist/AI Coding Proxy.app"
```

The app installs or updates the local LaunchAgent on first launch, then manages the daemon from the dashboard:

- `Overview` and `Settings` show LaunchAgent registration, runtime state, latest startup error, and local log paths.
- Closing the window hides the app; the daemon keeps serving until you explicitly stop it.
- `Dist/codex-proxyd-macos` can also be started manually for diagnostics after a direct `build-macos-app.sh` run.
- `Dist/remote-capable/codex-proxyd-macos` and `Dist/local-only/codex-proxyd-macos` are the matching packaged daemon binaries from the two release scripts.
- Remote-capable packaged apps embed `linux-amd64` and `linux-arm64` deployment packages under `Contents/Resources/RemoteArtifacts/`.
- Local-only packaged apps intentionally omit `Contents/Resources/RemoteArtifacts/`, so the `Deploy` / `Redeploy` action stays unavailable while the Remote page can still load status, inspect logs, and manage an already deployed host.

## Paths And Logs

Default local paths on macOS:

- Data directory: `~/Library/Application Support/CodexProxy`
- SQLite database: `~/Library/Application Support/CodexProxy/codex-proxy.sqlite3`
- Desktop preferences: `~/Library/Application Support/CodexProxy/desktop-preferences.json`
- LaunchAgent plist: `~/Library/LaunchAgents/io.shiguanghuxian.codex-proxy.plist`
- Daemon stdout log: `~/Library/Application Support/CodexProxy/daemon.out.log`
- Daemon stderr log: `~/Library/Application Support/CodexProxy/daemon.err.log`

Useful local diagnostics:

```bash
launchctl print "gui/$(id -u)/io.shiguanghuxian.codex-proxy"
tail -n 80 ~/Library/Application\ Support/CodexProxy/daemon.err.log
tail -n 80 ~/Library/Application\ Support/CodexProxy/daemon.out.log
```

## Upgrade And Uninstall

Upgrade flow:

- Replace `Dist/AI Coding Proxy.app` with the newer direct build, or unzip the matching archive from `Dist/remote-capable/` or `Dist/local-only/`.
- Launch the new app once; it rewrites the LaunchAgent plist if the daemon path, host, or ports changed.
- If you switch `auto_start` off, the desktop app will `bootout` the daemon and keep the plist only as an installed-but-disabled service definition.

Uninstall local service state:

```bash
launchctl bootout "gui/$(id -u)/io.shiguanghuxian.codex-proxy" || true
rm -f ~/Library/LaunchAgents/io.shiguanghuxian.codex-proxy.plist
rm -rf ~/Library/Application\ Support/CodexProxy
```

## Linux Deployment Packages

Bundled remote deployment packages are produced on macOS with the pinned Swift.org toolchain plus the Swift Static Linux SDK. Docker is no longer required.

```bash
./Scripts/prepare-swift-static-linux-sdk.sh
./Scripts/build-linux-artifacts.sh
```

Force a fresh `mihomo` download for both Linux artifact bundles:

```bash
./Scripts/build-linux-artifacts.sh --force-refresh
```

The preparation script validates the pinned Swift toolchain, installs the matching Static Linux SDK when needed, and keeps local builds aligned with CI/release packaging.

That script writes:

- `Artifacts/linux-amd64/codex-proxyd`
- `Artifacts/linux-amd64/mihomo`
- `Artifacts/linux-arm64/codex-proxyd`
- `Artifacts/linux-arm64/mihomo`

Downloaded `mihomo` binaries are cached under `ThirdParty/mihomo/` by target platform and architecture, and `Scripts/fetch-mihomo.sh --force-refresh [dest_dir] [arch] [platform]` lets you explicitly refresh one cache entry before copying it into a target output directory.

`Scripts/build-macos-app.sh` defaults to the remote-capable `full` profile and copies both complete packages into the app bundle so the Remote page can deploy or redeploy directly from the app without runtime downloads, Docker, or local rebuilds during deploy.

Pass `local-only` as the fourth argument, or use `Scripts/package-local-release.sh`, when you only need local macOS runtime artifacts and want to omit bundled Linux deployment packages. That profile still supports remote status/log/service management for already deployed hosts, but it disables in-app remote deployment and redeployment.
