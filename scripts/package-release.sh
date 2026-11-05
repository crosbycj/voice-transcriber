#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$APP_ROOT/Resources/Info.plist"
ENTITLEMENTS_PLIST="$APP_ROOT/Resources/Entitlements.plist"
BUILD_SCRIPT="$SCRIPT_DIR/build-app.sh"
SIGNING_IDENTITY="Developer ID Application: Cooper Crosby (6T84KQCNUF)"
EXPECTED_BUNDLE_ID="com.cooper.VoiceTranscriber"

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh [--staple-only]

Build, sign, notarize, staple, and zip Voice Transcriber.app.

Environment:
  NOTARY_PROFILE  Keychain profile created by `xcrun notarytool store-credentials`.

Options:
  --staple-only   Staple and package the retained app after a manual notarization.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null
}

STAPLE_ONLY=0
case "${1:-}" in
  "") ;;
  --staple-only) STAPLE_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; fail "unknown argument: $1" ;;
esac
[[ $# -le 1 ]] || { usage >&2; fail "too many arguments"; }

for command_name in codesign ditto plutil security shasum spctl xcrun; do
  require_command "$command_name"
done

VERSION="$(plist_value CFBundleShortVersionString "$INFO_PLIST")" ||
  fail "CFBundleShortVersionString is missing from Resources/Info.plist"
BUILD_NUMBER="$(plist_value CFBundleVersion "$INFO_PLIST")" ||
  fail "CFBundleVersion is missing from Resources/Info.plist"
BUNDLE_ID="$(plist_value CFBundleIdentifier "$INFO_PLIST")" ||
  fail "CFBundleIdentifier is missing from Resources/Info.plist"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]] ||
  fail "release version '$VERSION' is not a concrete semantic version"
case "${VERSION:l}" in
  0.0.0|*placeholder*|*snapshot*|*development*|*dev*|*changeme*|*todo*)
    fail "release version '$VERSION' looks like a placeholder"
    ;;
esac
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ && "$BUILD_NUMBER" -ge 1 ]] ||
  fail "build number '$BUILD_NUMBER' must be a positive integer"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] ||
  fail "expected production bundle ID '$EXPECTED_BUNDLE_ID', found '$BUNDLE_ID'"

SOURCE_AUDIO_INPUT="$(plist_value com.apple.security.device.audio-input "$ENTITLEMENTS_PLIST")" ||
  fail "the release entitlements do not contain com.apple.security.device.audio-input"
[[ "$SOURCE_AUDIO_INPUT" == "true" ]] ||
  fail "com.apple.security.device.audio-input must be enabled"

DIST_DIR="$APP_ROOT/dist"
WORK_DIR="$APP_ROOT/build/release-package"
APP_BUNDLE="$WORK_DIR/Voice Transcriber.app"
SUBMISSION_DIR="$DIST_DIR/.notarization"
SUBMISSION_ZIP="$SUBMISSION_DIR/Voice-Transcriber-$VERSION.zip"
FINAL_ZIP="$DIST_DIR/Voice-Transcriber-$VERSION.zip"
SIGNED_ENTITLEMENTS="$WORK_DIR/signed-entitlements.plist"

verify_signature() {
  local app_bundle="$1"
  local signature_details
  local app_bundle_id app_display_name app_version app_build

  app_bundle_id="$(plist_value CFBundleIdentifier "$app_bundle/Contents/Info.plist")"
  app_display_name="$(plist_value CFBundleDisplayName "$app_bundle/Contents/Info.plist")"
  app_version="$(plist_value CFBundleShortVersionString "$app_bundle/Contents/Info.plist")"
  app_build="$(plist_value CFBundleVersion "$app_bundle/Contents/Info.plist")"
  [[ "$app_bundle_id" == "$EXPECTED_BUNDLE_ID" ]] ||
    fail "packaged app has unexpected bundle ID '$app_bundle_id'"
  [[ "$app_display_name" == "Voice Transcriber" ]] ||
    fail "packaged app has non-production display name '$app_display_name'"
  [[ "$app_version" == "$VERSION" && "$app_build" == "$BUILD_NUMBER" ]] ||
    fail "packaged app version '$app_version ($app_build)' does not match '$VERSION ($BUILD_NUMBER)'"

  codesign --verify --strict --deep --verbose=2 "$app_bundle"
  signature_details="$(codesign --display --verbose=4 "$app_bundle" 2>&1)"
  echo "$signature_details"
  [[ "$signature_details" == *"Authority=$SIGNING_IDENTITY"* ]] ||
    fail "the app is not signed by the expected Developer ID identity"
  [[ "$signature_details" == *"runtime"* ]] ||
    fail "the app signature does not enable the hardened runtime"
  [[ "$signature_details" == *"Timestamp="* ]] ||
    fail "the app signature does not contain a secure timestamp"

  codesign --display --entitlements :- "$app_bundle" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
  plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
  local signed_audio_input
  signed_audio_input="$(plist_value com.apple.security.device.audio-input "$SIGNED_ENTITLEMENTS")" ||
    fail "the signed app is missing the audio-input entitlement"
  [[ "$signed_audio_input" == "true" ]] ||
    fail "the signed app's audio-input entitlement is not enabled"
}

verify_notarized_app() {
  local app_bundle="$1"
  local spctl_output

  verify_signature "$app_bundle"
  xcrun stapler validate "$app_bundle"

  if ! spctl_output="$(spctl -a -t exec -vv "$app_bundle" 2>&1)"; then
    echo "$spctl_output" >&2
    fail "Gatekeeper rejected the app"
  fi
  echo "$spctl_output"
  [[ "$spctl_output" == *"source=Notarized Developer ID"* ]] ||
    fail "Gatekeeper did not report 'source=Notarized Developer ID'"
}

print_manual_handoff() {
  cat >&2 <<EOF

Notarization could not be completed automatically. The signed submission and app
have been retained. After storing or selecting valid credentials, run exactly:

  export NOTARY_PROFILE="your-keychain-profile"
  xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "\$NOTARY_PROFILE" --wait

Then staple, validate, and create the final zip with:

  "$SCRIPT_DIR/package-release.sh" --staple-only

The staple-only step uses:
  App:        $APP_BUNDLE
  Final zip:  $FINAL_ZIP
EOF
}

if [[ "$STAPLE_ONLY" == "0" ]]; then
  AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
  [[ "$AVAILABLE_IDENTITIES" == *"\"$SIGNING_IDENTITY\""* ]] ||
    fail "Developer ID signing identity is not available: $SIGNING_IDENTITY"

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR" "$SUBMISSION_DIR"
  rm -f "$SUBMISSION_ZIP" "$FINAL_ZIP"

  echo "Building Voice Transcriber $VERSION ($BUILD_NUMBER) in release configuration..."
  BUILT_APP="$(
    VT_CODESIGN_IDENTITY="$SIGNING_IDENTITY" \
      VT_SKIP_INSTALL=1 \
      "$BUILD_SCRIPT" --release
  )"
  [[ "$BUILT_APP" == "$APP_ROOT/build/Voice Transcriber.app" ]] ||
    fail "build script returned an unexpected app path: $BUILT_APP"

  ditto "$BUILT_APP" "$APP_BUNDLE"

  # No additional hardened-runtime exceptions are needed. CGEventTap and event
  # posting are authorized by Input Monitoring/Accessibility TCC consent;
  # AVAudioEngine capture is covered by audio-input plus microphone consent; and
  # Core ML performs its own model compilation. In particular, do not add
  # allow-jit, allow-unsigned-executable-memory, or disable-library-validation.
  verify_signature "$APP_BUNDLE"

  echo "Creating notarization submission: $SUBMISSION_ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$SUBMISSION_ZIP"

  if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "error: NOTARY_PROFILE is not set; stopping at the notarization submit step." >&2
    print_manual_handoff
    exit 2
  fi

  echo "Submitting to Apple's notary service with keychain profile '$NOTARY_PROFILE'..."
  if ! xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "error: notarytool submission failed." >&2
    print_manual_handoff
    exit 1
  fi
else
  [[ -d "$APP_BUNDLE" ]] ||
    fail "retained app not found at '$APP_BUNDLE'; run the full packaging command first"
  verify_signature "$APP_BUNDLE"
fi

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"

echo "Running final release gates..."
verify_notarized_app "$APP_BUNDLE"

rm -f "$FINAL_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP"

echo "Final artifact: $FINAL_ZIP"
shasum -a 256 "$FINAL_ZIP"
