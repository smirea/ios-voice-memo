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

The local library uses one protected, atomic manifest per recording in `Records/`, with a stable ID assigned before capture begins. Migration preserves the original `entries.json` byte for byte and imports healthy notes individually; damaged records are reported and left untouched. Saves update only changed manifests off the main actor. Deletion intent is persisted before audio cleanup, and failed recording saves retain the audio for retry.

Permanent captures use continuous AAC in an ADTS `.aac` file, so already-written packets remain readable after abrupt process termination. After Finish or recovery, a native background export remuxes AAC into M4A without another lossy encode. Older PCM CAF captures can also be converted. The app validates the output, publishes it, and atomically commits the original note's manifest before removing the source. A failed export or metadata save keeps the source for retry; a restart between publication and manifest commit reuses the validated M4A. Pending source files are playable locally and are not mirrored to iCloud until preparation succeeds. Codec and filesystem buffers can still lose the latest tail of a recording.

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An iPhone or iPhone Simulator

## Run

Open `VoiceMemo.xcodeproj`, select the `VoiceMemo` scheme, and run on an iOS 26 iPhone target.

Add `-demo` to load sample content. Use `-demo-entry`, `-demo-reminders`, `-demo-reminder-feedback`, `-demo-review`, `-demo-recording`, `-demo-settings`, or `-demo-reminder-benchmark` to open a state directly.

In a Debug build, launch with `-demo -recording-contract-tests -playback-contract-tests -storage-contract-tests -audio-finalization-contract-tests` to check startup cancellation, audio recovery races, media resets, playback session ownership, damaged metadata migration, incremental saves, recovery identity, native M4A remux, truncated AAC tails, export/metadata failures, cancellation, and deletion during finalization with isolated temporary storage and no microphone access. Add `-demo-audio-reset` to `-demo-recording` or `-demo-reminder-feedback` to inspect the stopped recording UI. Use `-demo -demo-entry -demo-finalization-failed` to inspect preparation retry status.

For a synthetic process-kill recovery check in the Simulator, launch a Debug build with `-demo -audio-crash-writer <new-UUID>`, wait for `AUDIO_CAPTURE_READY`, and kill that process. Relaunch with `-demo -audio-recovery-verify <same-UUID>` and expect `AUDIO_RECOVERY_VERIFIED` with the same recording ID. The writer uses native AAC encoding, keeps the file open, and needs no microphone. `-audio-publication-writer <new-UUID>` instead emits `AUDIO_PUBLICATION_READY` after M4A publication but before its manifest commit; kill and verify it the same way. These fixtures use isolated temporary storage and test native file recovery, not microphone hardware or device power-loss behavior.

Query the Apple Intelligence model in the booted iPhone Simulator:

```sh
Scripts/query-local-model.sh "Explain why the sky is blue in one sentence."
```

See [`docs/reminder-model-evaluation.md`](docs/reminder-model-evaluation.md) for simulator benchmark commands and the current baseline.

## TestFlight

The Xcode Cloud `Default` workflow archives every push to `master` and distributes successful builds to the internal `me` testing group. Xcode Cloud manages sequential build numbers.
