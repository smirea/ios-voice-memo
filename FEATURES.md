> Keep one concise bullet for every user-visible feature and interaction. This file is the app's behavioral contract: review it whenever the app changes so existing interactions and specific behaviors are not accidentally lost or broken. Keep it brief and avoid implementation details or precise styling.

# General

- Supports only the latest iOS and uses native interactions and components where possible.
- Uses a consistent dark interface, saturated blue accent, and Liquid Glass controls.
- Never places content in decorative background boxes; uses spacing, typography, alignment, and dividers for hierarchy.
- Uses native horizontal back navigation wherever a back button is hidden.
- Stores notes and audio locally for offline use, includes them in device backups, continues processing briefly in the background, and retries interrupted or stalled processing after 15 minutes or on the next launch.
- Mirrors completed recordings to `iCloud Drive/MyVoiceMemo` as matching `YYYY-MM-DD_<city>__<UUID>.m4a` and `.json` files, backfills existing notes, and replaces temporary `Unknown` city names once resolved.
- Stores app settings, named locations, and API keys in a versioned, backed-up `config.json`, mirrors it beside iCloud Drive exports, and restores it when no local config exists.
- Treats local data as authoritative: iCloud note exports are not imported, and deleting a note removes its local audio and exports.
- Stores each note's transcript, title, summary, location, attached event, reminders, feedback transcripts, and model provenance in its JSON export.
- Prefers ElevenLabs transcription when enabled and reachable while Apple Speech supplies live partials and automatic fallback, and alerts when ElevenLabs could not be used; titles, summaries, reminders, and weekly reviews remain on-device and address the note owner as **you**.
- Generates summaries only for recordings longer than 20 seconds.
- Extracts event-specific reminders from event-attached recordings using the behavior defined in [`docs/reminder-model.md`](docs/reminder-model.md).
- Captures each recording's original coordinates and city when available, then resolves shared place names using the behavior in [`docs/location-model.md`](docs/location-model.md).
- Silently refreshes and caches included events from one month ago through three months ahead when the app opens or returns to the foreground, at most once per day, without changing calendar data.

# Home Screen

- Shows the current date, Settings, and all notes in a continuously scrolling reverse-chronological list.
- Each note shows its date, time, duration, title, and any active processing status; tapping it opens the **Note Screen**.
- Swiping a note left reveals a trash button; tapping it requires deletion confirmation.
- Shows an empty state when there are no notes.
- Floating Review and Record buttons open their respective screens.

# Record Screen

- Opens event setup instantly from Home using cached events, with a tappable date and the included events for that day in chronological order.
- Explains and disables event attachment when Calendar sync is off or the selected day has no events.
- Selects an ongoing timed event by default, otherwise the event closest to the current time.
- Turning **Attached to event** off clears, shrinks, and dims the list; tapping an event selects it for the new note.
- Start Recording begins with the selected event attached; a widget launch starts immediately without setup.
- Shows an error and returns home when recording cannot start.
- Records without a fixed time limit and shows a live waveform, elapsed time, pause/resume, finish, and discard controls.
- Finishing saves the note and opens its **Note Screen**; discarding deletes the recording and returns Home.
- Recording controls provide haptic feedback when enabled in Settings.
- Continues with the screen locked or app backgrounded, pauses for audio interruptions, and recovers from route changes when the microphone becomes available.
- Checkpoints audio for crash recovery and captures location without blocking recording.

# Note Screen

- Has no visible back button and uses the native leading-edge back swipe.
- Shows a saved place name or the captured city with the compact date, truncating long names; without location it shows `Voice memo` and omits the map.
- Shows an attached event below the header with a calendar icon.
- Tapping an attached event opens that exact event using its provider link when available, otherwise in a native event detail view.
- Shows the generated title, processing status, and audio controls with waveform progress and remaining time; playback stops on exit.
- Shows a short generated summary for recordings longer than 20 seconds and attributes the analysis model below the summary or title.
- Shows event reminders directly below the summary with compact frequency, quoted target, and duration; tapping uses native disclosure to expand its rationale without extra top or leading padding, swiping left removes it immediately, and an empty list shows only **No reminders: Add feedback**.
- **Add Feedback** records and transcribes a short correction, deletes the temporary audio, and reprocesses only the reminders.
- A bottom-left glass button morphs into note actions that persist **Show Models** app-wide with the whole toggle row tappable, reprocess the saved audio through transcription and all generated analysis even after leaving the note while safely queuing other reprocesses, and share complete metadata as a `.json` file with a separate **Copy JSON Text** action.
- When enabled in Settings, shows a four-line transcript preview and its transcription model.
- Tapping the transcript opens a selectable full-screen reader with Copy, Close, and native back-swipe controls.
- Shows the resolved place above a noninteractive Apple map; tapping only its label morphs it into an inline name editor with an editable Apple Maps address and autocomplete.
- The location editor lists other named places within 10 miles alphabetically with note counts and distance; selecting one assigns this note coordinate to that place.
- Saved place names apply to notes within 200 meters, while the selected address controls the map pin and Google Maps destination.
- Tapping anywhere on the map opens the resolved pin in the Google Maps app, with Google Maps web as a fallback.

# Review Screen

- Generates the current week's review on open, showing a loading state followed by the week, title, trend, and reflection.
- Uses the standard back button and native back swipe to return home.

# Settings Screen

- Opens as a sheet, saves changes immediately, and dismisses with Done.
- Controls screen wake while recording, recording haptics, transcript visibility, and the default-on ElevenLabs transcription preference.
- Stores an optional ElevenLabs API key in `config.json` and prefers it over the bundled fallback.
- Calendar sync requests Full Access for read-only event access and lets each calendar be included or excluded.
- Calendar settings can prefer direct Google Calendar links, with an exact native event view as fallback.
- Reminder settings control delivery, Live Activities, and the global pre-event lead time.
- Reminder Benchmark runs the production parser against grouped on-device accuracy, grounding, feedback, and fuzzy-matching cases.
- Delete All Entries requires confirmation and removes every note, recording, and iCloud Drive export.

# Lock Screen and Dynamic Island

- A Lock Screen circular microphone widget opens the app and starts a recording.
- Recording starts a Live Activity showing the app icon, location, date, state, and elapsed time on the Lock Screen and Dynamic Island.
- Pausing freezes the displayed elapsed time; resuming restarts it.
- Finishing or discarding a recording immediately clears the Live Activity.
- Enabled event reminders schedule a Live Activity before matching events and mark it stale when the event ends.
