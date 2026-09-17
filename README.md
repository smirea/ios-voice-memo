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
- Foundation Models guided titles, summaries for longer recordings, and weekly reviews with explicit incomplete or unavailable outcomes
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

Mirroring runs off the main actor with one coalescing worker. Each pass indexes the export directory once, writes only changed metadata, and reuses successfully copied audio while repairing missing files. Exact content acknowledgments and successful file signatures persist across restarts. Failed work remains eligible at the same revision with finite persisted backoff, and a foreground visit, account change, or manual retry rechecks it. A resolved city replaces its old export pair only after both new files succeed. Cleanup recognizes generated recording filenames and leaves unrelated files alone. New passes wait while recording has priority. These files are local iCloud provider exports; a completed local write does not establish upload to another device.

Configuration storage distinguishes readable, missing, unavailable, damaged, unsupported, and conflicting data. A readable local `config.json` remains authoritative. First-install changes are saved with their original baseline until discovery can safely restore or conditionally create cloud configuration; an unavailable provider never causes a defaults overwrite. Settings updates apply individual current-value edits, and restoration preserves explicit API-key clearing. Notes export independently of unresolved configuration. See [cloud storage behavior](docs/cloud-storage.md) for commit and provider boundaries.

The local library uses one protected, atomic manifest per recording in `Records/`, with a stable ID assigned before capture begins. Migration preserves the original `entries.json` byte for byte and imports healthy notes individually; damaged records are reported and left untouched. Saves update only changed manifests off the main actor. Deletion intent is persisted before audio cleanup, and failed recording saves retain the audio for retry.

Permanent captures use continuous AAC in an ADTS `.aac` file, so already-written packets remain readable after abrupt process termination. After Finish or recovery, a native background export remuxes AAC into M4A without another lossy encode. Older PCM CAF captures can also be converted. The app validates the output, publishes it, and atomically commits the original note's manifest before removing the source. A failed export or metadata save keeps the source for retry; a restart between publication and manifest commit reuses the validated M4A. Pending source files are playable locally and are not mirrored to iCloud until preparation succeeds. Codec and filesystem buffers can still lose the latest tail of a recording.

Processing is a durable part of each manifest: audio preparation, transcription, reflection, and reminders commit their own fields before advancing. A single worker owns the actual stage tasks, and request/attempt/source revisions reject stale results. Incomplete Apple text is stored separately from completed transcripts; failure and cancellation preserve prior completed content. Retry resumes the failed stage, while Reprocess starts a replacement transcription. Local edits retry narrow field changes rather than replaying older copies of the entire note. Pending reminder-source edits pause only that note’s processing; a failed save does not block another note’s writes or sharing. Reminder resolution uses committed source revisions, atomically saves pins and examples before delivery, and rejects stale results after edits, deletion, calendar replacement, or delivery changes. One owned activity reconciler serializes native updates and removals across asynchronous boundaries.

On-device requests account for the runtime context window, instructions, complete prompt, schema, and an output reserve. Native token counting is used on iOS 26.4 and later, with conservative UTF-8 accounting on earlier supported systems. Long reflections cover every ordered passage and reduce the resulting notes until the final request fits; each reduction must become smaller. Completed analysis notes include a versioned source fingerprint and are reused by weekly reviews only while the transcript matches. Long reminder extraction applies each later passage and correction across all accumulated candidates, with original-source evidence validation and bounded target context. Failed or incomplete calls never commit a partially processed memo as complete. Every actual model response retains its own deadline and recording cancellation priority.

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An iPhone or iPhone Simulator

## Run

Open `VoiceMemo.xcodeproj`, select the `VoiceMemo` scheme, and run on an iOS 26 iPhone target.

Add `-demo` to load sample content. Use `-demo-entry`, `-demo-reminders`, `-demo-reminder-feedback`, `-demo-review`, `-demo-recording`, `-demo-settings`, or `-demo-reminder-benchmark` to open a state directly.

In a Debug build, launch with `-demo -recording-contract-tests -playback-contract-tests -storage-contract-tests -audio-finalization-contract-tests -transcription-contract-tests -model-outcome-contract-tests -processing-repository-contract-tests -processing-worker-contract-tests -service-admission-contract-tests -processing-reliability-contract-tests -reminder-source-repository-contract-tests -reminder-scheduling-contract-tests -reminder-activity-contract-tests` to check startup cancellation, audio recovery races, media resets, playback session ownership, damaged metadata migration, incremental saves, recovery identity, native M4A remux, truncated AAC tails, export/metadata failures, cancellation, and deletion during finalization with isolated temporary storage and no microphone access. Admission and reliability checks also cover finite persisted retries, actual admitted-time deadlines, capture/background preemption, native cleanup quarantine, and startup temporary-file cleanup. Reminder contracts hold old results and native activity operations across replacements, inject manifest-write faults, verify durable pins and source preconditions, and isolate writes for different notes without requiring a calendar account or actual Live Activity delivery. Add `-demo-audio-reset` to `-demo-recording` or `-demo-reminder-feedback` to inspect the stopped recording UI. Use `-demo -demo-entry -demo-finalization-failed` to inspect preparation retry status, `-demo-processing-partial` for a newly saved note with incomplete text, or `-demo-processing-failed` for a failed replacement with prior analysis preserved. Use `-demo -demo-review -demo-review-unavailable` to inspect the weekly review retry state.

Use `-demo -icloud-mirror-contract-tests -icloud-store-contract-tests -cloud-state-contract-tests -cloud-file-access-contract-tests -icloud-provider-contract-tests -cloud-store-reliability-contract-tests` for real temporary-directory mirror faults, unchanged-write and directory-scan counters, missing-pair repair, exact deletion ownership, held-pass coalescing, same-revision retry, and mixed-library bootstrap. These checks also cover exact-content acknowledgments, persisted retry limits, provisional configuration restoration, current-value setting edits, native coordination cancellation, conditional creation races, and provider-state seams. They do not require an iCloud account or establish real provider upload, eviction, or cross-device conflict behavior. Use `-demo -demo-settings -demo-cloud-pending` or `-demo-configuration-damaged` to inspect the native retry footer.

Use `-demo -waveform-contract-tests -playback-contract-tests` for native PCM and AAC waveform decoding, exact end-of-file handling, cancellation during real buffer reads, file replacement and deletion, failed-read retry, bounded cache eviction, and playback load ownership. Waveforms use a shared memory cache of 64 completed envelopes; file identity invalidates replaced media, and leaving a note or starting capture cancels its utility decoder. These isolated fixtures require no microphone and do not establish physical-device performance.

Use `-demo -model-context-contract-tests -reflection-context-contract-tests -reminder-context-contract-tests -processing-repository-contract-tests` for lossless Unicode chunk boundaries, runtime tokenizer accounting, ordered whole-input coverage, finite reduction and context retries, cross-passage targets, late reminder corrections, cancellation, and durable analysis-note invalidation. Deterministic model substitutes verify processing mechanics; they do not establish native model semantic quality. The tokenizer check reports native availability separately from deterministic results.

Use `-demo -reminder-identity-contract-tests -reminder-validity-contract-tests` for durable one-time retirement and correction identities, inclusive occurrence expiration, pinned reminders that cannot drift to a substitute, and future-event filtering before fuzzy inference while preserving historical matching examples. These fixed-date checks require no calendar account or native model generation.

For a synthetic process-kill recovery check in the Simulator, launch a Debug build with `-demo -audio-crash-writer <new-UUID>`, wait for `AUDIO_CAPTURE_READY`, and kill that process. Relaunch with `-demo -audio-recovery-verify <same-UUID>` and expect `AUDIO_RECOVERY_VERIFIED` with the same recording ID. The writer uses native AAC encoding, keeps the file open, and needs no microphone. `-audio-publication-writer <new-UUID>` instead emits `AUDIO_PUBLICATION_READY` after M4A publication but before its manifest commit; kill and verify it the same way. These fixtures use isolated temporary storage and test native file recovery, not microphone hardware or device power-loss behavior.

Query the Apple Intelligence model in the booted iPhone Simulator:

```sh
Scripts/query-local-model.sh "Explain why the sky is blue in one sentence."
```

See [`docs/reminder-model-evaluation.md`](docs/reminder-model-evaluation.md) for simulator benchmark commands and the current baseline.

Use `-demo -recording-activity-contract-tests -recording-presentation-contract-tests` for held orphan cleanup, serialized recording activity replacement, capture-priority ordering, progress-backed freshness, frozen final durations, legacy state decoding, and capture-specific links. Isolated sessions use disabled native activities unless explicitly injected. Live Activity availability never gates audio startup.

Native recording presentation checks use `-demo -recording-activity-native-smoke`. For visual review, use `-demo -recording-activity-native-preview running` (also `paused`, `interrupted`, `waiting`, or `stale`) and `-recording-activity-native-preview-cleanup` afterward. The fixture leaves only its own activity visible. Use `-recording-activity-native-orphan-seed`, terminate the app, and relaunch with `-recording-activity-native-orphan-verify` to check startup cleanup. These native checks report actual API results separately; they do not establish real microphone capture, device background execution, system update throttling, or alert delivery. iOS can keep an old status visible after its freshness deadline. The running timer is explicitly estimated and has a native upper bound; a stale redraw switches to the exact last-confirmed duration.

## TestFlight

The Xcode Cloud `Default` workflow archives every push to `master` and distributes successful builds to the internal `me` testing group. Xcode Cloud manages sequential build numbers.
