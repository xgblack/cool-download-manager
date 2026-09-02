#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist"
DERIVED_DATA_DIR="$ROOT_DIR/.build/XcodePackageData"
VERSION_FILE="$ROOT_DIR/VERSION"
BUILD_NUMBER_FILE="$ROOT_DIR/BUILD_NUMBER"
REPOSITORY="${CDM_GITHUB_REPOSITORY:-xgblack/cool-download-manager}"
SPARKLE_ACCOUNT="${SPARKLE_ED25519_KEYCHAIN_ACCOUNT:-ed25519}"
VERSION=""
BUILD_NUMBER=""
VERSION="${CDM_VERSION:-$VERSION}"
BUILD_NUMBER="${CDM_BUILD_NUMBER:-$BUILD_NUMBER}"
RELEASE_TAG=""
NOTES_FILE=""
PUBLISH=0
SKIP_BUILD=0

usage() {
    cat <<'EOF'
Usage: scripts/publish-macos.sh [options]

Builds the Apple Silicon app, creates a signed Sparkle appcast, and optionally
publishes a GitHub Release. Publishing is opt-in; without --publish all assets
stay local.

Options:
  --version <version>              Product version (default: VERSION)
  --build-number <number>          Monotonic build number (default: BUILD_NUMBER)
  --output <directory>             Artifact directory (default: dist)
  --derived-data <directory>       Xcode derived data directory
  --repository <owner/name>        GitHub repository
  --release-tag <tag>              Release tag (default: v<version>)
  --notes-file <file>              GitHub release notes and appcast source notes
  --sparkle-account <account>      Keychain account (default: ed25519)
  --skip-build                     Reuse existing Xcode products
  --publish                        Create and publish the GitHub Release
  -h, --help                       Show this help

Environment:
  SPARKLE_ED25519_PRIVATE_KEY      Base64 encoded Sparkle private key. When set,
                                   it is sent to generate_appcast through stdin.
  SPARKLE_GENERATE_APPCAST         Explicit path to Sparkle generate_appcast
  SPARKLE_ED25519_KEYCHAIN_ACCOUNT Keychain account when the secret is omitted
  CDM_GITHUB_REPOSITORY            GitHub repository (default: xgblack/cool-download-manager)
  CDM_VERSION, CDM_BUILD_NUMBER
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --repository)
            [[ $# -ge 2 ]] || die "Missing value for --repository"
            REPOSITORY="$2"
            shift 2
            ;;
        --release-tag)
            [[ $# -ge 2 ]] || die "Missing value for --release-tag"
            RELEASE_TAG="$2"
            shift 2
            ;;
        --notes-file)
            [[ $# -ge 2 ]] || die "Missing value for --notes-file"
            NOTES_FILE="$2"
            shift 2
            ;;
        --sparkle-account)
            [[ $# -ge 2 ]] || die "Missing value for --sparkle-account"
            SPARKLE_ACCOUNT="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --publish)
            PUBLISH=1
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

if [[ -z "$VERSION" ]]; then
    [[ -f "$VERSION_FILE" ]] || die "Missing version file: $VERSION_FILE"
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
if [[ -z "$BUILD_NUMBER" ]]; then
    [[ -f "$BUILD_NUMBER_FILE" ]] || die "Missing build number file: $BUILD_NUMBER_FILE"
    BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Product version must contain three numeric components: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "Build number must contain only digits: $BUILD_NUMBER"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid GitHub repository: $REPOSITORY"

if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG="v$VERSION"
fi
[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Release tag must contain only letters, digits, '.', '_' or '-': $RELEASE_TAG"
[[ "$RELEASE_TAG" == "v$VERSION" ]] || die "Release tag must match product version (expected v$VERSION): $RELEASE_TAG"

if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || die "Release notes file does not exist: $NOTES_FILE"
fi

if [[ "$PUBLISH" -eq 1 && "$SKIP_BUILD" -eq 1 ]]; then
    die "--skip-build cannot be combined with --publish; publish only a freshly built artifact"
fi

validate_publish_preflight() {
    command -v gh >/dev/null 2>&1 || die "gh is required for --publish"
    if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
        die "Refusing to publish from a dirty worktree; commit or stash all changes first"
    fi
    if ! git rev-parse --verify "refs/tags/$RELEASE_TAG^{commit}" >/dev/null 2>&1; then
        die "Local Git tag $RELEASE_TAG does not exist; create and push the tag before publishing"
    fi

    TAG_COMMIT="$(git rev-parse "refs/tags/$RELEASE_TAG^{commit}")"
    HEAD_COMMIT="$(git rev-parse HEAD)"
    [[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] || die "Release tag $RELEASE_TAG does not point to HEAD"

    [[ -f "$VERSION_FILE" ]] || die "Missing version file: $VERSION_FILE"
    [[ -f "$BUILD_NUMBER_FILE" ]] || die "Missing build number file: $BUILD_NUMBER_FILE"
    SOURCE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
    SOURCE_BUILD_NUMBER="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
    [[ "$SOURCE_VERSION" == "$VERSION" ]] || die "VERSION file does not match release version: $SOURCE_VERSION != $VERSION"
    [[ "$SOURCE_BUILD_NUMBER" == "$BUILD_NUMBER" ]] || die "BUILD_NUMBER file does not match release build number: $SOURCE_BUILD_NUMBER != $BUILD_NUMBER"

    MAX_PREVIOUS_BUILD=0
    MAX_PREVIOUS_TAG=""
    while IFS= read -r tag; do
        [[ "$tag" == "$RELEASE_TAG" ]] && continue
        tag_build="$(git show "$tag:BUILD_NUMBER" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "$tag_build" =~ ^[0-9]+$ ]] || continue
        if (( 10#$tag_build > 10#$MAX_PREVIOUS_BUILD )); then
            MAX_PREVIOUS_BUILD="$tag_build"
            MAX_PREVIOUS_TAG="$tag"
        fi
    done < <(git for-each-ref --format='%(refname:short)' 'refs/tags/v*')

    if (( 10#$BUILD_NUMBER <= 10#$MAX_PREVIOUS_BUILD )); then
        die "Build number must be greater than previous release $MAX_PREVIOUS_TAG ($MAX_PREVIOUS_BUILD): $BUILD_NUMBER"
    fi

    if gh release view "$RELEASE_TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
        die "GitHub Release already exists for $RELEASE_TAG; refusing to overwrite it"
    fi
}

if [[ "$PUBLISH" -eq 1 ]]; then
    validate_publish_preflight
fi

PACKAGE_ARGS=(
    --version "$VERSION"
    --build-number "$BUILD_NUMBER"
    --output "$OUTPUT_DIR"
    --derived-data "$DERIVED_DATA_DIR"
    --zip
    --dmg
)
if [[ "$SKIP_BUILD" -eq 1 ]]; then
    PACKAGE_ARGS+=(--skip-build)
fi

"$ROOT_DIR/scripts/package-macos.sh" "${PACKAGE_ARGS[@]}"

ZIP_PATH="$OUTPUT_DIR/CoolDownloadManager-macOS-arm64.zip"
DMG_PATH="$OUTPUT_DIR/CoolDownloadManager-macOS-arm64.dmg"
APPCAST_PATH="$OUTPUT_DIR/appcast.xml"
ZIP_NAME="$(basename "$ZIP_PATH")"
[[ -f "$ZIP_PATH" ]] || die "Packaging did not create ZIP: $ZIP_PATH"
[[ -f "$DMG_PATH" ]] || die "Packaging did not create DMG: $DMG_PATH"

GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$GENERATE_APPCAST" ]]; then
    for candidate in \
        "$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        "$DERIVED_DATA_DIR/SourcePackages/checkouts/Sparkle/bin/generate_appcast"; do
        if [[ -x "$candidate" ]]; then
            GENERATE_APPCAST="$candidate"
            break
        fi
    done
fi
if [[ -z "$GENERATE_APPCAST" ]]; then
    GENERATE_APPCAST="$(find "$DERIVED_DATA_DIR" -type f -name generate_appcast -perm -111 -print -quit 2>/dev/null || true)"
fi
[[ -n "$GENERATE_APPCAST" && -x "$GENERATE_APPCAST" ]] || die "Sparkle generate_appcast was not found; build the app first or set SPARKLE_GENERATE_APPCAST"

SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
if [[ -z "$SPARKLE_SIGN_UPDATE" ]]; then
    for candidate in \
        "$(dirname "$GENERATE_APPCAST")/sign_update" \
        "$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" \
        "$DERIVED_DATA_DIR/SourcePackages/checkouts/Sparkle/bin/sign_update"; do
        if [[ -x "$candidate" ]]; then
            SPARKLE_SIGN_UPDATE="$candidate"
            break
        fi
    done
fi
[[ -n "$SPARKLE_SIGN_UPDATE" && -x "$SPARKLE_SIGN_UPDATE" ]] || die "Sparkle sign_update was not found; set SPARKLE_SIGN_UPDATE"

ARCHIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cooldm-appcast.XXXXXX")"
cleanup_archive_dir() {
    if [[ -n "${ARCHIVE_DIR:-}" && -d "$ARCHIVE_DIR" ]]; then
        rm -rf "$ARCHIVE_DIR"
    fi
}
trap cleanup_archive_dir EXIT

# The stable feed intentionally has only the newest arm64 update. Historical
# ZIP and DMG artifacts remain attached to their immutable GitHub Releases.
ditto "$ZIP_PATH" "$ARCHIVE_DIR/$ZIP_NAME"
if [[ -n "$NOTES_FILE" ]]; then
    NOTES_EXTENSION="${NOTES_FILE##*.}"
    case "$NOTES_EXTENSION" in
        md|markdown|html|htm|txt) ;;
        *) die "Release notes must use .md, .markdown, .html, .htm or .txt" ;;
    esac
    cp "$NOTES_FILE" "$ARCHIVE_DIR/${ZIP_NAME%.*}.$NOTES_EXTENSION"
fi

rm -f "$APPCAST_PATH"
DOWNLOAD_URL_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"
RELEASE_URL="https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
RELEASES_URL="https://github.com/$REPOSITORY/releases"
APPCAST_ARGS=(
    --download-url-prefix "$DOWNLOAD_URL_PREFIX"
    --full-release-notes-url "$RELEASE_URL"
    --link "$RELEASES_URL"
    --embed-release-notes
    -o "$APPCAST_PATH"
)

echo "==> Generating signed appcast with Sparkle"
if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
    # Keep the private key out of command arguments, temporary files, and logs.
    if ! printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | \
        "$GENERATE_APPCAST" --ed-key-file - "${APPCAST_ARGS[@]}" "$ARCHIVE_DIR" >/dev/null 2>&1; then
        die "Sparkle appcast generation failed; private key input was not logged"
    fi
else
    "$GENERATE_APPCAST" --account "$SPARKLE_ACCOUNT" "${APPCAST_ARGS[@]}" "$ARCHIVE_DIR"
fi

[[ -s "$APPCAST_PATH" ]] || die "Sparkle did not create appcast: $APPCAST_PATH"
command -v xmllint >/dev/null 2>&1 || die "xmllint is required to validate the generated appcast"
if ! grep -Fq 'sparkle:edSignature=' "$APPCAST_PATH"; then
    die "Generated appcast has no Ed25519 enclosure signature"
fi
if ! grep -Fq "$ZIP_NAME" "$APPCAST_PATH"; then
    die "Generated appcast does not reference $ZIP_NAME"
fi
if ! grep -Fq "$DOWNLOAD_URL_PREFIX$ZIP_NAME" "$APPCAST_PATH"; then
    die "Generated appcast does not use the immutable release URL"
fi
xmllint --noout "$APPCAST_PATH"
if ! grep -Fq '<!-- sparkle-signatures:' "$APPCAST_PATH" || \
   ! grep -Eq 'edSignature:[[:space:]]*[A-Za-z0-9+/=]{80,}' "$APPCAST_PATH"; then
    die "Generated appcast has no Sparkle feed signature block"
fi

APPCAST_VERSION="$(xmllint --xpath 'string(/rss/channel/item/*[local-name()="version"])' "$APPCAST_PATH")"
APPCAST_SHORT_VERSION="$(xmllint --xpath 'string(/rss/channel/item/*[local-name()="shortVersionString"])' "$APPCAST_PATH")"
APPCAST_ARCH="$(xmllint --xpath 'string(/rss/channel/item/*[local-name()="hardwareRequirements"])' "$APPCAST_PATH")"
APPCAST_ITEM_COUNT="$(xmllint --xpath 'count(/rss/channel/item)' "$APPCAST_PATH")"
ENCLOSURE_SIGNATURE="$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
ENCLOSURE_LENGTH="$(xmllint --xpath 'string(/rss/channel/item/enclosure/@length)' "$APPCAST_PATH")"
ZIP_LENGTH="$(stat -f '%z' "$ZIP_PATH")"
[[ "$APPCAST_VERSION" == "$BUILD_NUMBER" ]] || die "Appcast sparkle:version does not match build number: $APPCAST_VERSION != $BUILD_NUMBER"
[[ "$APPCAST_SHORT_VERSION" == "$VERSION" ]] || die "Appcast short version does not match product version: $APPCAST_SHORT_VERSION != $VERSION"
[[ "$APPCAST_ITEM_COUNT" == "1" ]] || die "Stable appcast must contain exactly one current update: $APPCAST_ITEM_COUNT"
[[ "$APPCAST_ARCH" == "arm64" ]] || die "Appcast hardware requirement does not identify arm64: $APPCAST_ARCH"
[[ "$ENCLOSURE_SIGNATURE" =~ ^[A-Za-z0-9+/=]{88}$ ]] || die "Appcast enclosure signature is not a 64-byte Ed25519 signature"
[[ "$ENCLOSURE_LENGTH" == "$ZIP_LENGTH" ]] || die "Appcast enclosure length does not match ZIP: $ENCLOSURE_LENGTH != $ZIP_LENGTH"

verify_with_sparkle_key() {
    if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
        if ! printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | \
            "$SPARKLE_SIGN_UPDATE" --ed-key-file - "$@" >/dev/null 2>&1; then
            return 1
        fi
    else
        "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$@" >/dev/null
    fi
}

echo "==> Verifying ZIP Ed25519 signature with Sparkle"
verify_with_sparkle_key --verify "$ZIP_PATH" "$ENCLOSURE_SIGNATURE" || \
    die "Sparkle ZIP signature verification failed"
echo "==> Verifying signed appcast with Sparkle"
if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
    if ! printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | \
        "$SPARKLE_SIGN_UPDATE" --ed-key-file - --verify "$APPCAST_PATH" >/dev/null 2>&1; then
        die "Sparkle appcast verification failed; private key input was not logged"
    fi
else
    "$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$APPCAST_PATH"
fi

echo "==> Release tag: $RELEASE_TAG"
echo "==> Product version: $VERSION"
echo "==> Build number: $BUILD_NUMBER"
echo "==> ZIP SHA-256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "==> DMG SHA-256: $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "==> Appcast: $APPCAST_PATH"
echo "==> Manual DMG: $DMG_PATH"
echo "==> Sparkle feed: https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"

if [[ "$PUBLISH" -eq 1 ]]; then
    RELEASE_ARGS=(release create "$RELEASE_TAG" --repo "$REPOSITORY" --verify-tag --draft --title "酷的下载管理器 $VERSION")
    if [[ -n "$NOTES_FILE" ]]; then
        RELEASE_ARGS+=(--notes-file "$NOTES_FILE")
    else
        RELEASE_ARGS+=(--generate-notes)
    fi
    echo "==> Creating draft GitHub Release"
    gh "${RELEASE_ARGS[@]}"

    echo "==> Uploading ZIP and manual DMG"
    gh release upload "$RELEASE_TAG" "$ZIP_PATH" "$DMG_PATH" --repo "$REPOSITORY"

    # Keep the stable latest/download/appcast.xml URL unavailable until the
    # immutable update archive assets are already present on the draft release.
    echo "==> Uploading signed appcast last"
    gh release upload "$RELEASE_TAG" "$APPCAST_PATH" --repo "$REPOSITORY"

    echo "==> Publishing GitHub Release"
    gh release edit "$RELEASE_TAG" --repo "$REPOSITORY" --draft=false --latest
fi
