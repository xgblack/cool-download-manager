# Native macOS implementation

The root Swift package is the first vertical slice of the native rewrite.
It contains:

- `CoolDownloadCore`: actor-based storage, HTTP/Range downloads, optional parallel range connections, ETag/Last-Modified validation, HLS media playlist downloads, pause/resume, bounded scheduling, queue metadata/start, finite transient retries, atomic `.dl-<id>.abdm.part` files, legacy record/parts JSON projection, and recovery state.
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

Run the `CoolDownloadManager` scheme for the SwiftUI/AppKit app. The current
SwiftPM executable is a development target; app-bundle settings, signing,
notarization, DMG packaging, installed-browser manifest verification,
proxy/PAC configuration, and full visual parity remain release-phase work.
They are tracked in the Swift rewrite plan under
`.helloagents/plans/swift-native-macos-rewrite/`.

For local integration smoke tests, the app keeps the legacy default of an unauthenticated loopback API on port `15151`. Set `CDM_API_KEY` to require `X-Api-Key`, or `CDM_HTTP_PORT` to use another loopback port. These environment overrides are temporary until the native settings screen owns the same values.

The app uses at most three active downloads by default. Set `CDM_MAX_CONCURRENT_DOWNLOADS` to change that limit. A download uses one HTTP connection by default; set `CDM_RANGE_CONNECTIONS` to a value greater than one to enable parallel byte ranges when the server advertises or confirms Range support. Range metadata and validators are persisted with the download record so a paused task can resume without treating a changed resource as the same file.

The current implementation deliberately does not claim release completeness: proxy/PAC/DNS policy, checksum verification, settings/categories, updater, Xcode bundle signing/notarization, and real installed-browser acceptance are still open items in the plan.
