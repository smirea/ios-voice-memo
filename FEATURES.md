> Keep one concise bullet for every user-visible feature and interaction. This file is the app's behavioral contract: review it whenever the app changes so existing interactions and specific behaviors are not accidentally lost or broken. Keep it brief and avoid implementation details or precise styling.

# General

- Supports only the latest iOS and uses native interactions and components where possible.
- Uses iOS's native horizontal back swipe without dragging screens vertically.
- Uses a consistent dark interface, saturated blue accent, and Liquid Glass controls.
- Never places content in decorative background boxes; uses spacing and typography for hierarchy.
- Stores notes and recordings locally for offline access and includes them in device backups.
- Mirrors each completed recording to `iCloud Drive/MyVoiceMemo` as matching `YYYY-MM-DD_<city>__<UUID>.m4a` and `.json` files.
- Stores the note's transcript, summary, title, generated observations, location, attached event, and model details in its matching iCloud Drive JSON file.
- Backfills existing recordings to iCloud Drive and replaces temporary `Unknown` city filenames after a city resolves.
- Treats local app data as the source of truth; edits made directly to iCloud Drive exports are not imported.
- Deleting notes also removes their local audio and matching iCloud Drive exports.
- Recovers nonempty audio from an interrupted recording when the app next launches.
- Resumes interrupted transcription, summary, and title generation when the app next launches.
- Transcribes recordings on-device, shows partial results live, and records the transcription model.
- Generates note titles and weekly reviews on-device with guided output, ignoring filler and transcription artifacts, with a fallback when the system model is unavailable.
- Generates a short on-device summary for recordings longer than 20 seconds.
- Captures the recording location when permitted and asks system location services for the city name.
- Refreshes the included calendars' events silently when the app opens or returns to the foreground after Calendar sync is enabled.
- Reads calendar data without creating, changing, or deleting events.

# Home Screen

- Shows the current date at the top left and a Liquid Glass Settings button at the top right.
- Shows all notes in a continuously scrolling reverse-chronological list.
- Each note shows its date and time on the left, duration on the right, and title below.
- A note being processed shows its current transcription or analysis status.
- Tapping a note opens the **Note Screen**.
- Swiping a note left reveals a trash button; tapping it requires deletion confirmation.
- Shows an empty state when there are no notes.
- A floating Liquid Glass Review button at the bottom left opens the **Review Screen**.
- A floating primary Record button at the bottom right opens the **Record Screen**.

# Record Screen

- Opens an event-attachment setup before recording when launched from the Home Screen.
- Shows the selected date as the screen title.
- Tapping the date opens the standard calendar picker.
- Shows the selected date's included calendar events in chronological order.
- Disables event attachment and explains when Calendar sync is off or there are no events on the selected date.
- Selects an ongoing timed event by default, otherwise the event closest to the current time.
- Attached to event can be turned off to unselect, shrink, and dim the event list.
- Tapping an event selects it for the new note.
- Start recording begins the recording with the selected event attached.
- Shows an error and returns home when recording cannot start.
- Records continuously until finished or discarded, with no fixed time limit.
- Shows a live waveform and elapsed recording time.
- A Liquid Glass play/pause control pauses and resumes recording.
- A finish control saves the recording and immediately opens its **Note Screen**.
- A red Liquid Glass trash control discards the recording and returns home.
- Recording controls provide haptic feedback when enabled in Settings.
- Continues recording with the screen locked or the app in the background.
- Pauses for audio interruptions and resumes when the microphone becomes available.
- Recovers from microphone route changes and shows a status when recording cannot resume.
- Saves progress during recording so interrupted sessions can be recovered.
- Captures location while recording without blocking recording when location is unavailable.

# Note Screen

- Has no visible back button; a leading-edge back swipe always returns Home.
- Shows the city on the left and a date such as `Thu Jul 23` on the right, adding the year only when it is not current.
- Truncates long city names instead of crowding the date.
- Uses `Voice memo` and omits the map when no recorded location is available.
- Shows an attached event as a plain row directly below the header with a calendar icon.
- Tapping an attached event opens that exact event using its provider link when available, otherwise in a native event detail view.
- Shows the generated note title centered below the header.
- Shows live transcription and analysis status after recording finishes; processing continues after navigating away.
- Provides play/pause, waveform progress, and remaining-time controls for the recording.
- Stops playback when leaving the note.
- Shows a short generated summary above the transcript for recordings longer than 20 seconds.
- Shows the analysis model below the summary, or below the title when no summary is generated, aligned right.
- Shows the transcript when enabled in Settings as a plain preview truncated after four lines.
- Tapping the transcript preview pushes a full-screen reader that can be closed or swiped back.
- The transcript reader allows text selection and has a copy button at the bottom left.
- The transcript reader has a Liquid Glass close button at the top right.
- Shows the transcription model below the transcript, aligned right.
- Shows the city with a map pin above a noninteractive Apple map.
- Tapping anywhere on the map opens the recorded coordinates in the Google Maps app, with Google Maps web as a fallback.

# Review Screen

- Generates a review for the current week when opened.
- Shows a loading state while the weekly review is generated.
- Shows the week, generated title, trend, and reflection.
- Uses the standard back button and native back swipe to return home.

# Settings Screen

- Opens as a sheet and dismisses with Done.
- Saves setting changes immediately.
- Keep Screen Awake prevents automatic screen lock while recording.
- Haptics enables recording-control feedback.
- Show Transcripts controls transcript visibility on note screens.
- Calendar sync requests iOS Full Access so it can read events, while the app itself remains read-only.
- Calendar settings allow each available calendar to be included or excluded.
- Calendar settings prefer direct Google Calendar event links when available, with an exact native event view as the fallback.
- Delete All Entries requires confirmation and removes every note, recording, and iCloud Drive export.

# Lock Screen and Dynamic Island

- A Lock Screen circular microphone widget opens the app and starts a recording.
- Recording starts a Live Activity with the app icon, location, date, and live elapsed time.
- The Dynamic Island shows the app icon, recording or paused state, location, and elapsed time.
- Pausing freezes the displayed elapsed time and resuming restarts it.
- Finishing or discarding a recording immediately clears the Live Activity.
