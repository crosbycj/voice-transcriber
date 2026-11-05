# Distributing Voice Transcriber

Voice Transcriber is distributed directly as a Developer ID-signed, notarized,
and stapled zip. The release script does not install or launch the app.

## One-time notarization setup

The Developer ID certificate
`Developer ID Application: Cooper Crosby (6T84KQCNUF)` must be available in the
login keychain.

Notary credentials are stored in Keychain under a profile name. If another
project already uses `notarytool` for the same Apple Developer team, reuse that
profile; profiles are not tied to a particular app or bundle ID. Validate it:

```bash
xcrun notarytool history --keychain-profile "voice-transcriber-notary"
```

To create a fresh profile with an Apple ID and app-specific password:

```bash
xcrun notarytool store-credentials "voice-transcriber-notary" \
  --apple-id "your-apple-id@example.com" \
  --team-id "6T84KQCNUF"
```

Create the app-specific password at appleid.apple.com and paste it at the secure
prompt. `store-credentials` validates the credentials before saving them; the
password does not go in the repository, command history, or packaging command.

## Package a release

From the repository root:

```bash
NOTARY_PROFILE="voice-transcriber-notary" scripts/package-release.sh
```

The script reads the release version and build number from
`Resources/Info.plist`, performs a Swift release build, signs with the hardened
runtime and the existing entitlements, submits to Apple's notary service,
staples the ticket, and runs strict `codesign`, Gatekeeper, and stapler checks.
The final artifact is:

```text
dist/Voice-Transcriber-0.1.0.zip
```

If credentials are unavailable, the script stops only after it has built,
signed, verified, and created the submission zip. It prints the exact
`notarytool submit` command. Once that command succeeds, resume without
rebuilding or resubmitting:

```bash
scripts/package-release.sh --staple-only
```

The retained app and submission zip live under `build/release-package` and
`dist/.notarization`, respectively. Both locations are ignored by Git.

## Recipient instructions

1. Unzip `Voice-Transcriber-0.1.0.zip`.
2. Drag **Voice Transcriber.app** to `/Applications`.
3. Launch Voice Transcriber. On first run, it downloads the approximately 600 MB
   speech model used for on-device transcription.
4. Grant **Microphone** access when macOS prompts.
5. Open the menu bar item and choose **Enable Use Anywhere**, then grant both
   **Input Monitoring** and **Accessibility** access in System Settings. These
   permissions are required for the keyboard-driven global shortcut and for
   placing dictated text into the active app.

There is currently no auto-update mechanism. Send a newly packaged zip for each
release.
