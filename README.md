# MyVoiceMemo

An iPhone voice memo app that records, transcribes, organizes, and carries useful context into upcoming calendar events.

## Goals

1. Record reliably through screen lock, audio-route changes, and interruptions.
2. Preserve audio continuously while recording and recover interrupted sessions.
3. Keep recordings available offline and mirror them to a browsable iCloud Drive folder.

## Features

- Record, pause, resume, and finish voice memos
- Background recording with interruption and microphone-route recovery
- Recording checkpoints and recovery after an interrupted app session
- Live recording state on the Lock Screen and Dynamic Island
- Location, date, and elapsed time in the recording Live Activity
- One-tap Lock Screen recording widget
- Long-form, on-device transcription with live partial results
- Audio playback with waveform scrubbing
- Foundation Models guided titles, summaries for longer recordings, and weekly reviews with deterministic fallbacks
- Model provenance stored with generated content
- Read-only calendar sync with per-calendar inclusion
- Optional calendar-event attachment before recording
- On-device extraction of event-specific reminders with recurring, one-time, fuzzy, and expiring schedules
- Reminder correction by disposable voice feedback
- Native note actions for model-label visibility, full reprocessing, and JSON sharing
- Configurable pre-event reminder Live Activities
- A permanent 72-case on-device reminder benchmark
- Exact calendar event details with direct Google Calendar links when available
- Reverse-chronological timeline, weekly reviews, and recorded locations
- Swipe-to-delete notes with confirmation
- Protected JSON and audio storage
- Browsable audio and metadata pairs in iCloud Drive

## Storage

The app keeps its working data in the private `Application Support/MyVoiceMemo` container for reliable offline recording and playback. It also mirrors every completed recording to `iCloud Drive/MyVoiceMemo` as a matching `.m4a` and `.json` pair named `YYYY-MM-DD_<city>__<UUID>`. The JSON contains the transcript, title, summary, location, attached event, reminders, feedback transcripts, and model provenance. Existing recordings are backfilled when the app launches. Deleting a note removes both mirrored files; edits made directly to the exports are not imported back into the app.

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An iPhone or iPhone Simulator

## Run

Open `VoiceMemo.xcodeproj`, select the `VoiceMemo` scheme, and run on an iOS 26 iPhone target.

Add `-demo` to load sample content. Use `-demo-entry`, `-demo-reminders`, `-demo-reminder-feedback`, `-demo-review`, `-demo-recording`, `-demo-settings`, or `-demo-reminder-benchmark` to open a state directly.

Query the Apple Intelligence model in the booted iPhone Simulator:

```sh
Scripts/query-local-model.sh "Explain why the sky is blue in one sentence."
```

See [`docs/reminder-model-evaluation.md`](docs/reminder-model-evaluation.md) for simulator benchmark commands and the current baseline.

## TestFlight

The Xcode Cloud `Default` workflow archives every push to `master` and distributes successful builds to the internal `me` testing group. Xcode Cloud manages sequential build numbers.
