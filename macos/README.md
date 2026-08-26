# 酷的下载管理器 macOS 原生版本

The root Swift package is the native macOS implementation.
It contains:

- `CoolDownloadCore`: actor-based storage under `~/.cooldm`, HTTP/Range downloads, optional parallel range connections, ETag/Last-Modified validation, HLS media playlist downloads, pause/resume, bounded scheduling, queue policies and completion events, finite transient retries, atomic `.dl-<id>.cooldm.part` files, JSON record/parts projection, and recovery state.
- `CoolDownloadIntegration`: loopback HTTP API on `127.0.0.1:15151`, API-key validation, Native Messaging framing, private Unix socket, queue listing, and manifest installation.
- `CoolDownloadManager`: SwiftUI/AppKit executable that owns the core directly.
- `CoolDownloadManagerNativeMessagingHost`: short-lived stdio adapter for the existing browser extension.
- `CoolDownloadManagerCLI`: small private-socket client for smoke checks.

Build and test with the Command Line Tools or Xcode:

```sh
swift test --filter CoolDownloadCoreTests --disable-sandbox
swift test --filter CoolDownloadIntegrationTests --disable-sandbox
swift build --disable-sandbox
```

For Xcode development, change to the repository root and open `Package.swift`;
do not open this documentation directory as a project:

```sh
cd /path/to/cool-download-manager
open Package.swift
```

Run the `CoolDownloadManager` scheme for the SwiftUI/AppKit app. The checked-in
script creates a local ad-hoc signed app bundle and DMG; Developer ID signing,
notarization, installed-browser manifest verification, proxy/PAC request
execution, custom DNS resolution, confirmed OS power actions, and full visual
parity remain release-phase work. They are tracked in the Swift rewrite plan under
`.helloagents/plans/swift-native-macos-rewrite/`.

Create a local app bundle or DMG from the repository root:

```sh
./scripts/package-macos.sh --dmg --zip
```

The script uses `Xcode-beta` when it is installed in `/Applications`, creates
an ad-hoc signed development bundle by default, and writes artifacts under
`dist/`. A Developer ID identity can be supplied with
`--signing-identity` for a distribution build.

For local integration smoke tests, the app keeps the legacy default of an unauthenticated loopback API on port `15151`. Set `CDM_API_KEY` to require `X-Api-Key`, or `CDM_HTTP_PORT` to use another loopback port. These environment overrides are temporary until the native settings screen owns the same values.

The app uses at most three active downloads by default. Set `CDM_MAX_CONCURRENT_DOWNLOADS` to change that limit. A download uses one HTTP connection by default; set `CDM_RANGE_CONNECTIONS` to a value greater than one to enable parallel byte ranges when the server advertises or confirms Range support. Range metadata and validators are persisted with the download record so a paused task can resume without treating a changed resource as the same file.

The current implementation deliberately does not claim release completeness:
custom DNS resolution, confirmed power-action execution, updater, Xcode bundle
signing/notarization, and real installed-browser acceptance are still open
items in the plan. Queue automatic-stop and completion events are implemented;
the core surfaces configured power actions to the UI instead of issuing them
without confirmation. Settings, categories, queues, task-level overrides, and
checksum UI are part of the current native vertical slice.
