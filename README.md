# 酷的下载管理器

酷的下载管理器正在使用 Swift 重写为原生 macOS 应用。当前分支包含
SwiftUI/AppKit 应用、纯 Swift 下载核心、浏览器集成服务、Native Messaging
宿主和命令行客户端。

The browser extension remains unchanged. The existing extension still requires
these Native Messaging protocol identifiers:

- Native Messaging host: `com.abdownloadmanager`
- Chrome origin: `chrome-extension://bbobopahenonfdgjgaleledndnnfhooj/`
- Firefox extension ID: `firefox-integration@abdownloadmanager.com`
- Loopback HTTP port: `15151`

The native application uses new private identifiers and does not migrate data
from the old desktop application:

- Bundle ID: `com.cooldownloadmanager`
- Data directory: `~/.cooldm`
- Default download directory: `~/Downloads/CoolDM`
- Incomplete file suffix: `.cooldm.part`

## Current Scope

The macOS vertical slice currently covers:

- HTTP and HTTPS downloads with pause, resume, retries, and persisted state
- HTTP Range probing and parallel byte-range downloads
- HLS master/media playlists and ordered segment assembly
- JSON download records, parts sidecars, and `.dl-<id>.cooldm.part` files
- Loopback HTTP compatibility endpoints and API-key validation
- Native Messaging framing and a private Unix-socket bridge to the app
- Basic SwiftUI download list actions: add, start, pause, retry, remove, queue,
  category, checksum, and completion flows
- Persistent settings, per-host overrides, queue scheduling, and task-level
  thread/speed overrides, proxy/PAC selection, proxy authentication, and
  optional server `Last-Modified` timestamps
- Queue-specific concurrency, automatic-stop policy, and one-shot completion
  events surfaced to the macOS UI

Custom DNS resolution, confirmed OS power-action execution, app
signing/notarization, and real installed-browser acceptance remain release work.
Queue completion actions are persisted and surfaced as an explicit UI notice;
the core never issues a shutdown/sleep command without a macOS confirmation
flow. DNS server addresses are stored and validated for migration compatibility,
but URLSession does not expose a per-session resolver API. The implementation
status and compatibility decisions are tracked in
`.helloagents/plans/swift-native-macos-rewrite/`.

## Build And Test

Requirements:

- macOS 13 or newer
- Swift 6 toolchain from Xcode or the macOS Command Line Tools

From the repository root:

```sh
swift test --filter CoolDownloadCoreTests --disable-sandbox
swift test --filter CoolDownloadIntegrationTests --disable-sandbox
swift build --disable-sandbox
```

## Open In Xcode

The repository root `Package.swift` is the source of truth for the Swift
package. With the full Xcode installation selected, open it directly:

```sh
open Package.swift
```

Select the `CoolDownloadManager` scheme to run the SwiftUI/AppKit executable.
The `CoolDownloadManagerNativeMessagingHost` and `CoolDownloadManagerCLI`
schemes are available for integration smoke tests. No generated
`.xcodeproj` is committed; Xcode reads the package manifest and keeps the
target graph in sync with SwiftPM. The checked-in packaging script creates a
local app bundle, while Developer ID signing, notarization, and installed
browser acceptance remain release work.

The root package produces these development executables:

```text
CoolDownloadManager
CoolDownloadManagerNativeMessagingHost
CoolDownloadManagerCLI
```

## Package A macOS App

Use the checked-in packaging script for a local `.app` and optional archives.
It automatically selects `/Applications/Xcode-beta.app` when present. DMG
packaging uses `create-dmg` to produce the standard drag-to-Applications Finder
window, so install that tool once before requesting a DMG:

```sh
brew install create-dmg
./scripts/package-macos.sh --dmg --zip
```

The outputs are written to `dist/`. The default `-` signing identity is an
ad-hoc signature for local execution only. For distribution, pass a Developer
ID identity and use the resulting app/DMG in the normal notarization workflow:

```sh
./scripts/package-macos.sh \
  --signing-identity "Developer ID Application: Your Name (TEAMID)" \
  --dmg --zip
```

The bundle contains the main app, `CoolDownloadManagerNativeMessagingHost`,
and `CoolDownloadManagerCLI` under `Contents/MacOS`. The app installs the
browser manifest at runtime, so test the installed bundle from its final
location rather than moving it after the first launch.

Run the CLI against a running app:

```sh
swift run CoolDownloadManagerCLI ping
swift run CoolDownloadManagerCLI add https://example.com/file.zip
```

For local integration checks, the app uses an unauthenticated loopback API
on port `15151` by default. Temporary environment overrides are available:

```sh
CDM_API_KEY=change-me
CDM_HTTP_PORT=15151
CDM_MAX_CONCURRENT_DOWNLOADS=3
CDM_RANGE_CONNECTIONS=1
```

The Native Messaging manifest is written to the standard Chrome, Chromium,
and Firefox per-user directories when the app runs from an installed bundle.
The development executable can be supplied with `CDM_NATIVE_HOST_PATH` when
testing manifest generation.

## Architecture

The UI and download core run in one Swift process and communicate through
actors and typed Swift calls. The browser compatibility surfaces are the only
process boundaries:

```text
SwiftUI/AppKit -> DownloadService actor -> storage and network

Browser extension -> loopback HTTP -> main app
Browser extension -> Native Messaging host -> private Unix socket -> main app
```

The Native Messaging host contains no download logic. It forwards requests,
starts the main app when necessary, and writes only valid framed responses to
stdout; diagnostics go to stderr.

## Compatibility And Migration

The Swift branch is a complete rewrite and no longer builds the deleted
Kotlin/Gradle application. The Swift core is the only process allowed to write
the `.cooldm` data directory. Files under the old `~/.abdm` directory are not
automatically migrated or read by this version. Do not run an older Compose
build against the new data directory.

The browser extension source is maintained separately at
[`amir1376/ab-download-manager-browser-integration`](https://github.com/amir1376/ab-download-manager-browser-integration).
No extension changes are required for the Native Messaging values above.

## License

This project retains the upstream license and notices in `LICENSE`.
