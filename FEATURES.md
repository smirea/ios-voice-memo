> Keep one concise bullet for every user-visible feature and interaction. This file is the app's behavioral contract: review it whenever the app changes so existing interactions and specific behaviors are not accidentally lost or broken. Keep it brief and avoid implementation details or precise styling.

# General

- Supports only the latest iOS and uses native interactions and components where possible.
- Uses iOS's native horizontal back swipe without dragging screens vertically.
- Uses a consistent dark interface, saturated blue accent, and Liquid Glass controls.
- Stores notes and recordings locally for offline access and includes them in device backups.
- Mirrors each completed recording to `iCloud Drive/MyVoiceMemo` as matching `YYYY-MM-DD_<city>__<UUID>.m4a` and `.json` files.
- Stores the note's transcript, title, tags, location, and model details in its matching iCloud Drive JSON file.
- Backfills existing recordings to iCloud Drive and replaces temporary `Unknown` city filenames after a city resolves.
- Treats local app data as the source of truth; edits made directly to iCloud Drive exports are not imported.
- Deleting notes also removes their local audio and matching iCloud Drive exports.
- Recovers nonempty audio from an interrupted recording when the app next launches.
- Transcribes recordings on-device, shows partial results live, and records the transcription model.
- Generates note titles and weekly reviews on-device, with a fallback when the system model is unavailable.
- Captures the recording location when permitted and asks system location services for the city name.

# Home Screen

- Shows the current date at the top left and a Liquid Glass Settings button at the top right.
- Shows all notes in a continuously scrolling reverse-chronological list.
- Each note shows its date and time on the left, duration on the right, and title below.
- A note being processed shows its current transcription or title-generation status.
- Tapping a note opens the **Note Screen**.
- Swiping a note left reveals a trash button; tapping it requires deletion confirmation.
- Shows an empty state when there are no notes.
- A floating Liquid Glass Review button at the bottom left opens the **Review Screen**.
- A floating primary Record button at the bottom right opens the **Record Screen**.

# Record Screen

- Starts recording immediately after microphone permission is granted.
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

- Has no visible back button; the native back swipe returns to the previous screen.
- Shows the city on the left and a date such as `Thu Jul 23` on the right, adding the year only when it is not current.
- Truncates long city names instead of crowding the date.
- Uses `Voice memo` and omits the map when no recorded location is available.
- Shows the generated note title centered below the header.
- Shows live transcription and title-generation status after recording finishes; processing continues after navigating away.
- Provides play/pause, waveform progress, and remaining-time controls for the recording.
- Stops playback when leaving the note.
- Shows the transcript when enabled in Settings and allows text selection.
- Collapses transcripts longer than four lines and only shows expand/collapse controls when content is hidden.
- Shows the transcription model below the transcript, aligned right.
- Shows the city with a map pin above a noninteractive Apple map.
- Tapping the map opens the recorded coordinates in Google Maps.

# Review Screen

- Generates a review for the current week when opened.
- Shows a loading state while the weekly review is generated.
- Shows the week, generated title, trend, reflection, and topic tags.
- Uses the standard back button and edge swipe to return home.

# Settings Screen

- Opens as a sheet and dismisses with Done.
- Saves setting changes immediately.
- Keep Screen Awake prevents automatic screen lock while recording.
- Haptics enables recording-control feedback.
- Show Transcripts controls transcript visibility on note screens.
- Delete All Entries requires confirmation and removes every note, recording, and iCloud Drive export.

# Lock Screen and Dynamic Island

- A Lock Screen circular microphone widget opens the app and starts a recording.
- Recording starts a Live Activity with the app icon, location, date, and live elapsed time.
- The Dynamic Island shows the app icon, recording or paused state, location, and elapsed time.
- Pausing freezes the displayed elapsed time and resuming restarts it.
- Finishing or discarding a recording immediately clears the Live Activity.
