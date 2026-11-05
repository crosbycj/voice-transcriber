# Voice Transcriber Spec

This repository contains the standalone native macOS voice transcription app:

- Menu bar-only SwiftUI app
- Global hotkeys via `CGEventTap`
- `AVAudioEngine` recording straight to durable storage, recovering from input failures mid-recording
- Local Parakeet transcription through FluidAudio
- Pasteboard swap-and-restore insertion with single-slot voice clipboard
