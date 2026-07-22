# MyVoiceMemo

An iPhone-only, local-first voice journal inspired by [Slate](https://apps.apple.com/us/app/slate-private-journal/id6787531627). This first milestone reproduces Slate's public recording, journal, entry, and weekly-review experience. Later iterations will add webhooks and integrations for AI agents.

# Target Functionality
1. Robust recording: audio is always saved and is consistent, even if the screen turns off, or microphone changes. audio is always saved on device while it's recording
2. Automatic iCloud backups always enabled
3. Local first: app should work while fully offline

## Current baseline

- Record, pause, resume, extend, finish, re-record, and delete voice entries
- Live recording state on the Lock Screen and Dynamic Island
- One-tap Lock Screen recording widget
- On-device speech transcription with no network fallback
- On-device Foundation Models reflections with a deterministic local fallback
- Private journal timeline, transcript, observations, tags, added context, and copy action
- Weekly summaries generated from that week's local entries
- Local JSON and audio storage protected by iOS file protection
- No backend, account, analytics SDK, or app-initiated network requests

## Requirements

- Xcode 26 or newer
- iOS 26 or newer
- An iPhone or iPhone Simulator

## Run

Open `VoiceMemo.xcodeproj`, select the `VoiceMemo` scheme, and run on an iOS 26 iPhone target.

Add `-demo` to the scheme's launch arguments to load the reference content used for visual comparison. The additional `-demo-entry`, `-demo-review`, and `-demo-recording` arguments open those states directly.

## Reference scope

The UI is matched to Slate's four published App Store screens and the behavior described in its listing. The original is iPhone-only and cannot be installed in Simulator, so private onboarding, subscription, settings, and optional encrypted iCloud backup flows could not be inspected and are not included in this baseline.
