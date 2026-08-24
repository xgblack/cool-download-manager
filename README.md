# Cool download manager

Cool download manager is being rewritten as a native macOS application in
Swift. The current branch contains the SwiftUI/AppKit application, a pure
Swift download core, the browser integration service, the Native Messaging
host, and a small command-line client.

The browser extension remains unchanged. The rewrite keeps the compatibility
identifiers used by released versions:

- Native Messaging host: `com.abdownloadmanager`
- Data directory: `~/.abdm`
- Chrome origin: `chrome-extension://bbobopahenonfdgjgaleledndnnfhooj/`
- Firefox extension ID: `firefox-integration@abdownloadmanager.com`
- Loopback HTTP port: `15151`

## Current Scope

The macOS vertical slice currently covers:

- HTTP and HTTPS downloads with pause, resume, retries, and persisted state
- HTTP Range probing and parallel byte-range downloads
- HLS master/media playlists and ordered segment assembly
- Legacy `.abdm` records, parts sidecars, and `.dl-<id>.abdm.part` files
- Loopback HTTP compatibility endpoints and API-key validation
- Native Messaging framing and a private Unix-socket bridge to the app
- Basic SwiftUI download list actions: add, start, pause, retry, and remove

Proxy/PAC/DNS policy, checksum verification, categories and settings, update
installation, app signing/notarization, DMG packaging, and real installed
browser acceptance remain release work. The implementation status and
compatibility decisions are tracked in
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
target graph in sync with SwiftPM. The current executable is a development
target, so app-bundle signing, notarization, and DMG packaging remain release
work.

The root package produces these development executables:

```text
CoolDownloadManager
CoolDownloadManagerNativeMessagingHost
CoolDownloadManagerCLI
```

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
Kotlin/Gradle application. The Swift core is the only process allowed to
write the `.abdm` data directory. Do not run an older Compose build against
the same data directory at the same time.

The browser extension source is maintained separately at
[`amir1376/ab-download-manager-browser-integration`](https://github.com/amir1376/ab-download-manager-browser-integration).
No extension changes are required for the compatibility values above.

## License

This project retains the upstream license and notices in `LICENSE`.
