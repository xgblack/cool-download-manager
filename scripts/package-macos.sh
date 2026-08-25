#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Release"
OUTPUT_DIR="$ROOT_DIR/dist"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodePackageData"
SIGNING_IDENTITY="${CDM_SIGNING_IDENTITY:--}"
VERSION="${CDM_VERSION:-0.1.0}"
MAKE_ZIP=0
MAKE_DMG=0
SKIP_BUILD=0

usage() {
    cat <<'EOF'
Usage: scripts/package-macos.sh [options]

Builds the SwiftPM macOS executable with Xcode and creates:
  dist/CoolDownloadManager.app

Options:
  --configuration <Debug|Release>  Build configuration (default: Release)
  --output <directory>             Output directory (default: dist)
  --derived-data <directory>       Xcode derived data directory
  --version <version>              Bundle version (default: 0.1.0)
  --signing-identity <identity>    codesign identity; '-' means ad hoc
  --no-sign                        Leave the bundle unsigned
  --zip                            Also create a zip archive
  --dmg                            Also create a compressed DMG
  --skip-build                     Reuse existing Xcode products
  -h, --help                       Show this help

Environment:
  DEVELOPER_DIR                    Xcode developer directory override
  CDM_DEVELOPER_DIR                Same override when DEVELOPER_DIR is unset
  CDM_SIGNING_IDENTITY             Default signing identity
  CDM_VERSION                      Default bundle version
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || { echo "Missing value for --configuration" >&2; exit 64; }
            CONFIGURATION="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { echo "Missing value for --output" >&2; exit 64; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --derived-data)
            [[ $# -ge 2 ]] || { echo "Missing value for --derived-data" >&2; exit 64; }
            DERIVED_DATA_DIR="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || { echo "Missing value for --version" >&2; exit 64; }
            VERSION="$2"
            shift 2
            ;;
        --signing-identity)
            [[ $# -ge 2 ]] || { echo "Missing value for --signing-identity" >&2; exit 64; }
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
    *)
        echo "Configuration must be Debug or Release: $CONFIGURATION" >&2
        exit 64
        ;;
esac

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -n "${CDM_DEVELOPER_DIR:-}" ]]; then
        export DEVELOPER_DIR="$CDM_DEVELOPER_DIR"
    elif [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    fi
fi

if [[ ! -x "${DEVELOPER_DIR:-}/usr/bin/xcodebuild" ]]; then
    echo "Xcode xcodebuild was not found. Set DEVELOPER_DIR to an Xcode installation." >&2
    exit 1
fi

PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION"
APP_NAME="CoolDownloadManager.app"
APP_DIR="$OUTPUT_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
ICON_FILE="$ROOT_DIR/packaging/macos/AppIcon.icns"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    mkdir -p "$DERIVED_DATA_DIR"
    for scheme in CoolDownloadManager CoolDownloadManagerNativeMessagingHost CoolDownloadManagerCLI; do
        echo "==> Building $scheme ($CONFIGURATION) with ${DEVELOPER_DIR}"
        xcodebuild \
            -scheme "$scheme" \
            -configuration "$CONFIGURATION" \
            -destination "platform=macOS" \
            -derivedDataPath "$DERIVED_DATA_DIR" \
            CODE_SIGNING_ALLOWED=NO \
            build
    done
fi

for executable in CoolDownloadManager CoolDownloadManagerNativeMessagingHost CoolDownloadManagerCLI; do
    if [[ ! -x "$PRODUCTS_DIR/$executable" ]]; then
        echo "Missing Xcode product: $PRODUCTS_DIR/$executable" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT_DIR"
if [[ -e "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi
mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"

if [[ ! -f "$ICON_FILE" ]]; then
    echo "Missing macOS application icon: $ICON_FILE" >&2
    exit 1
fi

cp "$PRODUCTS_DIR/CoolDownloadManager" "$MACOS_DIR/CoolDownloadManager"
cp "$PRODUCTS_DIR/CoolDownloadManagerNativeMessagingHost" "$MACOS_DIR/CoolDownloadManagerNativeMessagingHost"
cp "$PRODUCTS_DIR/CoolDownloadManagerCLI" "$MACOS_DIR/CoolDownloadManagerCLI"
cp "$ROOT_DIR/packaging/macos/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICON_FILE" "$CONTENTS_DIR/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS_DIR/Info.plist"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "==> Signing bundle with identity '$SIGNING_IDENTITY'"
    for executable in CoolDownloadManagerNativeMessagingHost CoolDownloadManagerCLI CoolDownloadManager; do
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$MACOS_DIR/$executable"
    done
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
else
    echo "==> Leaving bundle unsigned"
fi

ARCH="$(uname -m)"
if [[ "$MAKE_ZIP" -eq 1 ]]; then
    ZIP_PATH="$OUTPUT_DIR/CoolDownloadManager-macOS-$ARCH.zip"
    rm -f "$ZIP_PATH"
    echo "==> Creating $ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
fi

if [[ "$MAKE_DMG" -eq 1 ]]; then
    DMG_PATH="$OUTPUT_DIR/CoolDownloadManager-macOS-$ARCH.dmg"
    rm -f "$DMG_PATH"
    echo "==> Creating $DMG_PATH"
    hdiutil create \
        -volname "Cool download manager" \
        -srcfolder "$APP_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

echo "==> App bundle: $APP_DIR"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --verify --deep --strict "$APP_DIR"
    echo "==> codesign verification passed"
fi
