This is a simple iOS app that's only meant to support the latest iOS and should use as much as possible native interactions and components before reaching out to custom implementations

# Feature contract

- Read `FEATURES.md` before changing the app and review it again before finishing.
- Keep `FEATURES.md` updated whenever user-visible features, interactions, or specific behaviors change.
- Treat documented behavior as a regression checklist: do not accidentally remove, lose, or break it while changing something else.

# Visual review

- After completing any visual app change, capture the finished UI in the iOS Simulator and include screenshots of the changed screens or states in the final chat response.

# Non-negotiable visual rules

- NO CARDS: never place sections, rows, text, statuses, empty states, or other content inside decorative filled, tinted, material, bordered, or rounded containers.
- Use spacing, typography, alignment, and dividers for hierarchy. Background shapes are only for actual controls such as buttons or for clipping media.
- Do not delete, weaken, condense away, or reinterpret negative design constraints in `FEATURES.md`.
- Before finishing visual work, run `Scripts/check-design-rules.sh`; the Xcode build runs it too.

# Stack

- Language: Swift
- Package Manager: Swift Package Manager
- Minimum targets: iOS 17 and macOS 14
- Keep dependencies rare and intentional

# Deployment

- After pushing all commits to `master`, verify that the Xcode Cloud `Default` workflow has scheduled an actual build for the exact pushed commit SHA. A successful push or an empty queued GitHub check suite is not enough.
- If no build appears within five minutes, investigate the trigger and report that deployment has not started. Only report deployment as complete after the archive and TestFlight distribution succeed.
