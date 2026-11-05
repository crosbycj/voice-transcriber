# Voice Transcriber

Standalone native macOS menu bar app for local voice-to-text dictation.

Hold `fn` to dictate and release to paste, or press `fn`+`Space` while holding to lock the recording and press `fn` again to stop. `⌃⌘V` pastes the last transcript. Transcription runs locally through FluidAudio and Nvidia Parakeet Core ML models.

Accessibility permission is needed for global hotkeys and pasting, and Microphone permission for recording. Without Accessibility, transcripts are copied to the clipboard instead of pasted.

## Build and run

```bash
swift build
scripts/build-app.sh
scripts/run-app.sh
```

The bundling script produces `build/Voice Transcriber.app` and installs a development copy at `~/Applications/Voice Transcriber Dev.app`, quitting any running copy first.

Set `VT_CODESIGN_IDENTITY` to override the default Developer ID signing identity. `VT_INSTALL_DIR`, `VT_APP_NAME`, and `VT_INSTALL_PATH` override the development install destination.

## Test

The tests use Swift Testing, which needs Xcode's toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

To measure a transcription change against real audio, list WAV paths in a file and run:

```bash
swift run -c release vt-eval paths.txt
```

It prints one JSON object per recording: the transcript, words recovered or removed at the end, the microphone health verdict, and whether the speech check would have heard anyone 12 and 20 seconds in. Compare two runs before shipping a change. The transcript repairs in particular were tuned on real dictations, and a first attempt that looked right in unit tests was deleting real words.

## How a dictation stays safe

The rule is that audio outlives every failure.

1. **Recording.** `AudioRecorder` writes straight to its final file in `~/Library/Application Support/Voice Transcriber/recordings/`, refreshing the WAV header every second.
2. **Input failures.** `AVAudioEngine` can report a successful start and then die moments later without delivering anything, and a device can reconfigure or vanish mid-recording. The recorder rebuilds the input and keeps writing to the same file. The start sound plays only once real audio has arrived.
3. **Warnings.** `SignalMonitor` catches static and digital silence, and a stall watchdog catches an input that stops delivering. From twelve seconds in, the speech model checks whether anyone can actually be heard, until someone is; two misses in a row raise a warning, because one empty decode happens on normal speech. Trouble shows on the recording bar and plays a sound.
4. **Saving.** The recording enters `history.json` before transcription starts, and the transcript is saved before it's pasted. If saving fails the words are pasted anyway, and if the focused app changed during transcription they're copied instead.
5. **Crashes.** At launch, `TranscriptStore.recoverInterrupted` repairs and transcribes anything left unfinished. If `history.json` is damaged, it's rebuilt from the per-recording JSON sidecars.

A stop that hangs can't take the hotkey with it: after a deadline the app returns to idle, and the audio stays on disk. Canceling a recording of five seconds or more moves it to the Trash.

Each record keeps a `capture` report with the microphone used, restarts, and worst input health, for diagnosing what went wrong afterward.

## Transcript endings

Parakeet decodes 15 seconds at a time, and two problems show up at the end of a transcript. `TranscriptRepair` handles both.

- **Cut-off endings.** On recordings over 15 seconds, FluidAudio ends its last window at the final speech, which often loses the closing punctuation and occasionally a last word. The last 15 seconds are decoded again right up to the end of the file, and that can only add to what the main decode found. Padding the audio with silence is not a fix: it swaps which recordings lose their endings.
- **Invented filler.** The model tends to add a stray "Yeah." in the last moments of audio. It's removed only when it's a filler word, low confidence, within half a second of the end, and quieter than speech. Requiring a filler word matters, because real last words trail off just as quietly.
