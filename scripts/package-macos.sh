#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Release"
MACOS_DEPLOYMENT_TARGET="26.0"
OUTPUT_DIR="$ROOT_DIR/dist"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodePackageData"
SIGNING_IDENTITY="${CDM_SIGNING_IDENTITY:--}"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
VERSION=""
BUILD_NUMBER=""
DMG_BACKGROUND_FILE="$ROOT_DIR/packaging/macos/DMGBackground.png"
MAKE_ZIP=0
MAKE_DMG=0
SKIP_BUILD=0
ARCH="arm64"

usage() {
    cat <<'EOF'
Usage: scripts/package-macos.sh [options]

Builds the Apple Silicon SwiftPM macOS executable with Xcode and creates:
  dist/酷的下载管理器.app

The deployment target is fixed at macOS 26.0.

Options:
  --configuration <Debug|Release>  Build configuration (default: Release)
  --output <directory>             Output directory (default: dist)
  --derived-data <directory>       Xcode derived data directory
  --version <version>              CFBundleShortVersionString
  --build-number <number>          Monotonically increasing CFBundleVersion
  --signing-identity <identity>    codesign identity; '-' means ad hoc
  --no-sign                        Leave the bundle unsigned
  --zip                            Also create a zip archive
  --dmg                            Also create a drag-to-Applications DMG
  --skip-build                     Reuse existing Xcode products
  -h, --help                       Show this help

Environment:
  DEVELOPER_DIR                    Xcode developer directory override
  CDM_DEVELOPER_DIR                Same override when DEVELOPER_DIR is unset
  CDM_SIGNING_IDENTITY             Default signing identity
  CDM_VERSION                      Default product version
  CDM_BUILD_NUMBER                 Default build number
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || die "Missing value for --configuration"
            CONFIGURATION="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "Missing value for --output"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --derived-data)
            [[ $# -ge 2 ]] || die "Missing value for --derived-data"
            DERIVED_DATA_DIR="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || die "Missing value for --version"
            VERSION="$2"
            shift 2
            ;;
        --build-number)
            [[ $# -ge 2 ]] || die "Missing value for --build-number"
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --signing-identity)
            [[ $# -ge 2 ]] || die "Missing value for --signing-identity"
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --no-sign)
            SIGNING_IDENTITY=""
            shift
            ;;
        --zip)
            MAKE_ZIP=1
            shift
            ;;
        --dmg)
            MAKE_DMG=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

case "$CONFIGURATION" in
    Debug|Release) ;;
    *) die "Configuration must be Debug or Release: $CONFIGURATION" ;;
esac

if [[ -z "$VERSION" ]]; then
    [[ -f "$VERSION_FILE" ]] || die "Missing version file: $VERSION_FILE"
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
    VERSION="${CDM_VERSION:-$VERSION}"
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    [[ -f "$BUILD_NUMBER_FILE" ]] || die "Missing build number file: $BUILD_NUMBER_FILE"
    BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
    BUILD_NUMBER="${CDM_BUILD_NUMBER:-$BUILD_NUMBER}"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Version must contain three numeric components (for example 1.0.5): $VERSION"
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    die "Build number must contain only digits: $BUILD_NUMBER"
fi

if [[ "$MAKE_DMG" -eq 1 ]]; then
    if ! command -v create-dmg >/dev/null 2>&1; then
        die "create-dmg is required for DMG packaging. Install it with: brew install create-dmg"
    fi
    if [[ ! -f "$DMG_BACKGROUND_FILE" ]]; then
        die "Missing DMG background: $DMG_BACKGROUND_FILE"
    fi
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -n "${CDM_DEVELOPER_DIR:-}" ]]; then
        export DEVELOPER_DIR="$CDM_DEVELOPER_DIR"
    elif [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    fi
fi

if [[ -z "${DEVELOPER_DIR:-}" || ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    die "Xcode xcodebuild was not found. Set DEVELOPER_DIR to an Xcode installation."
fi

MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Swift 6.4 forwards its SDK as --sysroot, which currently leaves the Mach-O
# SDK field at the deployment target. Preserve macOS 26 compatibility while
# recording the actual SDK used for linked-on behavior.
PLATFORM_LINKER_FLAGS="-Xlinker -platform_version -Xlinker macos -Xlinker $MACOS_DEPLOYMENT_TARGET -Xlinker $MACOS_SDK_VERSION"

PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION"
APP_NAME="酷的下载管理器.app"
APP_DIR="$OUTPUT_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
LICENSES_DIR="$CONTENTS_DIR/Resources/Licenses"
ICON_FILE="$ROOT_DIR/packaging/macos/AppIcon.icns"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    mkdir -p "$DERIVED_DATA_DIR"
    for scheme in CoolDownloadManager CoolDownloadManagerNativeMessagingHost CoolDownloadManagerCLI; do
        echo "==> Building $scheme ($CONFIGURATION, $ARCH) with ${DEVELOPER_DIR}"
        xcodebuild \
            -scheme "$scheme" \
            -configuration "$CONFIGURATION" \
            -destination "platform=macOS,arch=$ARCH" \
            -derivedDataPath "$DERIVED_DATA_DIR" \
            ARCHS="$ARCH" \
            ONLY_ACTIVE_ARCH=YES \
            MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
            CODE_SIGNING_ALLOWED=NO \
            OTHER_LDFLAGS="$PLATFORM_LINKER_FLAGS" \
            build
    done
fi

for executable in CoolDownloadManager CoolDownloadManagerNativeMessagingHost CoolDownloadManagerCLI; do
    if [[ ! -x "$PRODUCTS_DIR/$executable" ]]; then
        die "Missing Xcode product: $PRODUCTS_DIR/$executable"
    fi
    if ! lipo -archs "$PRODUCTS_DIR/$executable" | tr ' ' '\n' | grep -Fxq "$ARCH"; then
        die "Xcode product $executable does not contain architecture $ARCH"
    fi
done

SPARKLE_FRAMEWORK_SOURCE=""
framework_contains_arm64() {
    local framework="$1"
    local binary="$framework/Versions/Current/Sparkle"
    [[ -d "$framework" && -x "$binary" ]] || return 1
    lipo -archs "$binary" | tr ' ' '\n' | grep -Fxq 'arm64'
}

# Prefer the product emitted by the selected Xcode build. Fall back to Sparkle's
# Apple Silicon XCFramework slice when Xcode does not copy it to Products.
for candidate in \
    "$PRODUCTS_DIR/Sparkle.framework" \
    "$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64/Sparkle.framework"; do
    if framework_contains_arm64 "$candidate"; then
        SPARKLE_FRAMEWORK_SOURCE="$candidate"
        break
    fi
done

if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
    # Keep a fallback for future Sparkle artifact layouts, but only accept an
    # embedded framework that contains an Apple Silicon slice.
    while IFS= read -r candidate; do
        if framework_contains_arm64 "$candidate"; then
            SPARKLE_FRAMEWORK_SOURCE="$candidate"
            break
        fi
    done < <(find "$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework" -type d -name 'Sparkle.framework' -print 2>/dev/null)
fi
[[ -n "$SPARKLE_FRAMEWORK_SOURCE" && -d "$SPARKLE_FRAMEWORK_SOURCE" ]] || die "Missing Sparkle.framework in Xcode products"
SPARKLE_BINARY_SOURCE="$SPARKLE_FRAMEWORK_SOURCE/Versions/Current/Sparkle"
SPARKLE_LICENSE_SOURCE="$DERIVED_DATA_DIR/SourcePackages/checkouts/Sparkle/LICENSE"
[[ -x "$SPARKLE_BINARY_SOURCE" ]] || die "Missing Sparkle framework executable: $SPARKLE_BINARY_SOURCE"
[[ -f "$SPARKLE_LICENSE_SOURCE" ]] || die "Missing Sparkle license: $SPARKLE_LICENSE_SOURCE"

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$LICENSES_DIR" "$FRAMEWORKS_DIR"

if [[ ! -f "$ICON_FILE" ]]; then
    die "Missing macOS application icon: $ICON_FILE"
fi

cp "$PRODUCTS_DIR/CoolDownloadManager" "$MACOS_DIR/CoolDownloadManager"
cp "$PRODUCTS_DIR/CoolDownloadManagerNativeMessagingHost" "$MACOS_DIR/CoolDownloadManagerNativeMessagingHost"
cp "$PRODUCTS_DIR/CoolDownloadManagerCLI" "$MACOS_DIR/CoolDownloadManagerCLI"
cp "$ROOT_DIR/packaging/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICON_FILE" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$ROOT_DIR/LICENSE" "$LICENSES_DIR/CoolDownloadManager.txt"
cp "$SPARKLE_LICENSE_SOURCE" "$LICENSES_DIR/Sparkle.txt"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS_DIR/Info.plist")" == "$VERSION" ]] || die "Packaged short version does not match $VERSION"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS_DIR/Info.plist")" == "$BUILD_NUMBER" ]] || die "Packaged build number does not match $BUILD_NUMBER"

MAIN_EXECUTABLE="$MACOS_DIR/CoolDownloadManager"
if ! otool -l "$MAIN_EXECUTABLE" | grep -Fq '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$MAIN_EXECUTABLE"
fi

sign_code() {
    local path="$1"
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        # Ad-hoc signatures do not carry a Team ID. Hardened runtime library
        # validation would therefore reject the separately ad-hoc-signed
        # Sparkle framework at launch, so leave runtime options off here.
        codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$path"
    else
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$path"
    fi
}

sign_sparkle_bundle() {
    local framework="$1"
    local updater_app="$framework/Versions/Current/Updater.app"
    local xpc
    local executable_name

    if [[ -d "$updater_app" ]]; then
        sign_code "$updater_app/Contents/MacOS/Updater"
        sign_code "$updater_app"
    fi

    for xpc in "$framework"/Versions/Current/XPCServices/*.xpc; do
        [[ -d "$xpc" ]] || continue
        executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$xpc/Contents/Info.plist")"
        sign_code "$xpc/Contents/MacOS/$executable_name"
        sign_code "$xpc"
    done

    sign_code "$framework/Versions/Current/Autoupdate"
    sign_code "$framework"
}

if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "==> Signing bundle with identity '$SIGNING_IDENTITY'"
    sign_sparkle_bundle "$FRAMEWORKS_DIR/Sparkle.framework"
    for executable in CoolDownloadManagerNativeMessagingHost CoolDownloadManagerCLI CoolDownloadManager; do
        sign_code "$MACOS_DIR/$executable"
    done
    sign_code "$APP_DIR"
else
    echo "==> Leaving bundle unsigned"
fi
if [[ "$MAKE_ZIP" -eq 1 ]]; then
    ZIP_PATH="$OUTPUT_DIR/CoolDownloadManager-macOS-$ARCH.zip"
    rm -f "$ZIP_PATH"
    echo "==> Creating $ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
fi

if [[ "$MAKE_DMG" -eq 1 ]]; then
    DMG_PATH="$OUTPUT_DIR/CoolDownloadManager-macOS-$ARCH.dmg"
    DMG_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cooldm-dmg.XXXXXX")"
    trap 'rm -rf "$DMG_STAGE_DIR"' EXIT

    ditto "$APP_DIR" "$DMG_STAGE_DIR/$APP_NAME"
    echo "==> Creating $DMG_PATH"
    create-dmg \
        --volname "酷的下载管理器" \
        --background "$DMG_BACKGROUND_FILE" \
        --window-pos 200 120 \
        --window-size 720 420 \
        --text-size 14 \
        --icon-size 112 \
        --icon "$APP_NAME" 170 220 \
        --hide-extension "$APP_NAME" \
        --app-drop-link-name "应用程序" \
        --app-drop-link 550 220 \
        --format UDZO \
        --no-internet-enable \
        --overwrite \
        "$DMG_PATH" \
        "$DMG_STAGE_DIR"

    rm -rf "$DMG_STAGE_DIR"
    trap - EXIT
fi

echo "==> App bundle: $APP_DIR"
echo "==> Product version: $VERSION"
echo "==> Build number: $BUILD_NUMBER"
echo "==> Architecture: $ARCH"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --verify --deep --strict "$APP_DIR"
    echo "==> codesign verification passed"
fi
if [[ "$MAKE_ZIP" -eq 1 ]]; then
    echo "==> ZIP: $ZIP_PATH"
fi
if [[ "$MAKE_DMG" -eq 1 ]]; then
    echo "==> DMG: $DMG_PATH"
fi
