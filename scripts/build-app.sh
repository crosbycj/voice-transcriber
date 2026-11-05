#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWIFT_HOME="$APP_ROOT/.swift-home"
REAL_HOME="${HOME:-$(dscl . -read "/Users/$USER" NFSHomeDirectory | awk '{print $2}')}"
BUNDLE_INFO_PLIST="$APP_ROOT/Resources/Info.plist"
ENTITLEMENTS_PLIST="$APP_ROOT/Resources/Entitlements.plist"
DEFAULT_CODESIGN_IDENTITY="Developer ID Application: Cooper Crosby (6T84KQCNUF)"

CONFIGURATION="debug"
if [[ "${1:-}" == "--release" ]]; then
  CONFIGURATION="release"
fi

SWIFT_FLAGS=()
if [[ "$CONFIGURATION" == "release" ]]; then
  SWIFT_FLAGS=(-c release)
fi

mkdir -p \
  "$SWIFT_HOME/.cache/clang/ModuleCache" \
  "$SWIFT_HOME/Library/Caches/org.swift.swiftpm" \
  "$SWIFT_HOME/Library/org.swift.swiftpm/configuration" \
  "$SWIFT_HOME/Library/org.swift.swiftpm/security"

SWIFT_BUILD_ENV=(
  HOME="$SWIFT_HOME"
  CLANG_MODULE_CACHE_PATH="$SWIFT_HOME/.cache/clang/ModuleCache"
  SWIFTPM_MODULECACHE_OVERRIDE="$SWIFT_HOME/.cache/clang/ModuleCache"
)

run_swift_build() {
  env "${SWIFT_BUILD_ENV[@]}" swift build --disable-sandbox --package-path "$APP_ROOT" "${SWIFT_FLAGS[@]}" "$@"
}

resolve_codesign_identity() {
  if [[ -n "${VT_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$VT_CODESIGN_IDENTITY"
    return
  fi

  local identity
  identity="$(
    security find-identity -v -p codesigning 2>/dev/null |
      awk -F'"' -v preferred="$DEFAULT_CODESIGN_IDENTITY" '$2 == preferred { print $2; exit }'
  )"

  if [[ -z "$identity" ]]; then
    identity="$(
      security find-identity -v -p codesigning 2>/dev/null |
        awk -F'"' '/Developer ID Application:/ { print $2; exit }'
    )"
  fi

  printf '%s\n' "$identity"
}

sign_bundle() {
  local app_bundle="$1"
  local identity="$2"
  local timestamp_args=(--timestamp)
  if [[ "$identity" == "-" ]]; then
    timestamp_args=(--timestamp=none)
  fi

  codesign --force --sign "$identity" "${timestamp_args[@]}" --options runtime --entitlements "$ENTITLEMENTS_PLIST" "$app_bundle"
}

quit_running_app() {
  local bundle_id="$1"

  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  sleep 0.5
}

run_swift_build >&2

BIN_DIR="$(run_swift_build --show-bin-path)"
BUILD_APP_BUNDLE="$APP_ROOT/build/Voice Transcriber.app"
CONTENTS_DIR="$BUILD_APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BUNDLE_INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUNDLE_INFO_PLIST")"
INSTALL_DIR="${VT_INSTALL_DIR:-$REAL_HOME/Applications}"
INSTALL_APP_NAME="${VT_APP_NAME:-Voice Transcriber Dev.app}"
INSTALL_APP_BUNDLE="${VT_INSTALL_PATH:-$INSTALL_DIR/$INSTALL_APP_NAME}"
IDENTITY="$(resolve_codesign_identity)"

rm -rf "$BUILD_APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUNDLE_INFO_PLIST" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/$EXECUTABLE_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
codesign --remove-signature "$MACOS_DIR/$EXECUTABLE_NAME"

ASSETS_DIR="$APP_ROOT/Sources/Resources/Assets.xcassets"
APP_ICON_SOURCE="$ASSETS_DIR/AppIcon.appiconset/icon.png"
if [[ -f "$APP_ICON_SOURCE" ]]; then
  ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET_TMP"
  sips -z 16 16     "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_16x16.png"      >/dev/null
  sips -z 32 32     "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_16x16@2x.png"   >/dev/null
  sips -z 32 32     "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_32x32.png"      >/dev/null
  sips -z 64 64     "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_32x32@2x.png"   >/dev/null
  sips -z 128 128   "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_128x128.png"    >/dev/null
  sips -z 256 256   "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_256x256.png"    >/dev/null
  sips -z 512 512   "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$APP_ICON_SOURCE" --out "$ICONSET_TMP/icon_512x512.png"    >/dev/null
  cp                "$APP_ICON_SOURCE"         "$ICONSET_TMP/icon_512x512@2x.png"
  node "$SCRIPT_DIR/create-icns.mjs" "$ICONSET_TMP" "$RESOURCES_DIR/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET_TMP")"
fi

MENU_BAR_ICON_SET="$ASSETS_DIR/MenuBarIconTemplate.imageset"
if [[ -f "$MENU_BAR_ICON_SET/icon.png" ]]; then
  cp "$MENU_BAR_ICON_SET/icon.png"    "$RESOURCES_DIR/MenuBarIconTemplate.png"
fi
if [[ -f "$MENU_BAR_ICON_SET/icon@2x.png" ]]; then
  cp "$MENU_BAR_ICON_SET/icon@2x.png" "$RESOURCES_DIR/MenuBarIconTemplate@2x.png"
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "warning: no stable code signing identity found; using ad hoc signing. Set VT_CODESIGN_IDENTITY to keep Accessibility and Microphone permissions from re-prompting after rebuilds." >&2
else
  echo "Using code signing identity: $IDENTITY" >&2
fi

sign_bundle "$BUILD_APP_BUNDLE" "$IDENTITY"

if [[ "${VT_SKIP_INSTALL:-0}" == "1" ]]; then
  printf '%s\n' "$BUILD_APP_BUNDLE"
  exit 0
fi

mkdir -p "$INSTALL_DIR"
quit_running_app "$BUNDLE_ID"
rm -rf "$INSTALL_APP_BUNDLE"
ditto "$BUILD_APP_BUNDLE" "$INSTALL_APP_BUNDLE"

printf '%s\n' "$INSTALL_APP_BUNDLE"
