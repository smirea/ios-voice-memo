# Reminder model benchmark

The app contains a permanent, on-device benchmark for the production reminder parser. Open **Settings → Reminder benchmark** to run the full corpus or one level at a time. The same runner can be invoked on an iPhone Simulator with:

```sh
xcrun simctl launch --terminate-running-process --console <device-id> \
  com.stefan.myvoicememo -reminder-benchmark
```

Use `-reminder-benchmark-group <id>` to run one of `direct`, `boundaries`, `schedule`, `speech`, `dense`, `feedback`, or `resolution`.

The cases live in `Sources/App/ReminderBenchmarkCases.swift`. They are compiled into the app so the same corpus can compare future system-model and parser revisions. The benchmark currently has 72 model-backed cases in seven levels plus eight deterministic contract checks:

1. Direct cues
2. Precision boundaries
3. Scheduling and targeting
4. Natural speech
5. Dense and adversarial memos
6. Feedback reprocessing
7. Fuzzy event resolution

The levels progress from literal instructions to filler, indirect intent, negation, ownership changes, self-correction, multiple simultaneous rules, changing event titles, semantic near misses, and corrections to an existing reminder set.

## Metrics

The runner reports:

- exact case passes;
- cue precision and recall;
- selector, occurrence, time, venue, and expiry field accuracy;
- exact evidence grounding;
- fuzzy-resolution case passes;
- deterministic contract checks;
- per-case latency and generated rules.

Extra reminders count against precision because irrelevant cues cost user attention. Evidence is grounded only when it is a nonempty contiguous excerpt of the memo or correction.

## July 24, 2026 simulator baseline

The benchmark was run inside the iPhone 17 Pro simulator on iOS 26.5 using `SystemLanguageModel.default`. The development Mac was not used as a substitute because it reported Apple Intelligence unavailable, while Foundation Models was available in the simulator.

The final coherent 72-case run after schema decomposition scored:

```text
exact cases: 70/72
cue precision: 100.0%
cue recall: 100.0%
schema field accuracy: 100.0%
exact evidence grounding: 100.0%
fuzzy resolution: 8/10
deterministic checks: 8/8
```

The two failures were positive fuzzy matches whose model calls took roughly 50 seconds and returned no accepted decision after the simulator had already processed the preceding 62 cases. The same fuzzy-resolution level passed 10/10 in an isolated run. This is useful evidence of sustained-run tail latency rather than a prompt or schema mismatch.

Targeted reruns also confirmed precision boundaries at 12/12 and feedback reprocessing at 8/8. The corpus is intentionally strict, and Foundation Models output is nondeterministic, so scores should be compared over complete runs rather than treated as permanent guarantees.

## Findings that changed the parser

- One large guided schema produced valid JSON-like shapes but mixed selector, recurrence, time, and duration values.
- Batch classification with opaque references caused decisions to leak between candidate events.
- Compact action drafts and one-candidate boolean classifications were materially more reliable.
- Explicit time, recurrence, relative duration, venue grounding, and obvious semantic conflicts are safer as deterministic validation.
- Feedback performs better as edits to the authoritative current set than as a fresh extraction from the original transcript.
- A small deterministic gate improves both latency and precision, while ambiguous ownership, quotation, and correction cases still benefit from the model.
