# MyVoiceMemo

An iPhone voice memo app that records, transcribes, summarizes, and organizes spoken notes.

## Goals

1. Record reliably through screen lock, audio-route changes, and interruptions.
2. Preserve audio continuously while recording and recover interrupted sessions.
3. Keep recordings available offline and include them in the iPhone's normal device backup.

## Features

- Record, pause, resume, extend, and finish voice memos
- Background recording with interruption and microphone-route recovery
- Recording checkpoints and recovery after an interrupted app session
- Live recording state on the Lock Screen and Dynamic Island
- One-tap Lock Screen recording widget
- Speech transcription with live partial results
- Foundation Models summaries with a deterministic fallback
- Model provenance stored with transcripts and summaries
- Timeline, tags, context, weekly summaries, and Apple Maps locations
- Protected JSON and audio storage

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An iPhone or iPhone Simulator

## Run

Open `VoiceMemo.xcodeproj`, select the `VoiceMemo` scheme, and run on an iOS 26 iPhone target.

Add `-demo` to load sample content. The additional `-demo-entry`, `-demo-review`, and `-demo-recording` launch arguments open those states directly.

## TestFlight

The Xcode Cloud `Default` workflow archives every push to `master` and distributes successful builds to the internal `me` testing group. Xcode Cloud manages sequential build numbers.
