# MyVoiceMemo

An iPhone voice memo app that records, transcribes, summarizes, and organizes spoken notes.

## Goals

1. Record reliably through screen lock, audio-route changes, and interruptions.
2. Preserve audio continuously while recording and recover interrupted sessions.
3. Keep recordings available offline and include them in the iPhone's normal device backup.

## Features

- Record, pause, resume, and finish voice memos
- Background recording with interruption and microphone-route recovery
- Recording checkpoints and recovery after an interrupted app session
- Live recording state on the Lock Screen and Dynamic Island
- Location, date, and elapsed time in the recording Live Activity
- One-tap Lock Screen recording widget
- Speech transcription with live partial results
- Foundation Models summaries with a deterministic fallback
- Model provenance stored with transcripts and summaries
- Timeline, tags, weekly summaries, and recorded locations
- Swipe-to-delete notes with confirmation
- Protected JSON and audio storage

## Storage

Audio files and note data live in the app's private `Application Support/MyVoiceMemo` container. iOS includes them in normal device backups, but they are not exposed as a browsable iCloud Drive or Files folder.

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An iPhone or iPhone Simulator

## Run

Open `VoiceMemo.xcodeproj`, select the `VoiceMemo` scheme, and run on an iOS 26 iPhone target.

Add `-demo` to load sample content. The additional `-demo-entry`, `-demo-review`, and `-demo-recording` launch arguments open those states directly.

## TestFlight

The Xcode Cloud `Default` workflow archives every push to `master` and distributes successful builds to the internal `me` testing group. Xcode Cloud manages sequential build numbers.
