# Reminder model benchmark

The app contains a permanent, on-device benchmark for the production reminder parser. Open **Settings → Reminder benchmark** to run the full corpus or one level at a time. The same runner can be invoked on an iPhone Simulator with:

```sh
xcrun simctl launch --terminate-running-process --console <device-id> \
  com.stefan.myvoicememo -reminder-benchmark
```

Use `-reminder-benchmark-group <id>` to run one of `direct`, `boundaries`, `schedule`, `speech`, `dense`, `feedback`, or `resolution`.
Use `-reminder-benchmark-case "<name fragment>"` to isolate one regression.
Use `-reminder-benchmark-deterministic-only` to verify the non-model contract checks when Foundation Models is unavailable.

The cases live in `Sources/App/ReminderBenchmarkCases.swift`. They are compiled into the app so the same corpus can compare future system-model and parser revisions. The benchmark currently has 73 model-backed cases in seven levels plus twelve deterministic contract checks:

1. Direct cues
2. Precision boundaries
3. Scheduling and targeting
4. Natural speech
5. Dense and adversarial memos
6. Feedback reprocessing
7. Fuzzy event resolution

The levels progress from literal instructions to filler, indirect intent, negation, ownership changes, self-correction, multiple simultaneous rules, changing event titles, semantic near misses, corrections to an existing reminder set, and shared goals spanning multiple named events.

## Metrics

Run status is complete, canceled, unavailable, or failed. Cancel and leaving the benchmark screen stop its owned run; already assessed cases remain visible as partial results. Execution failures are not red semantic failures and are excluded from accuracy denominators. Assessed, attempted, and total counts show coverage; empty denominators display Not assessed. A completed negative case can still pass exact case accuracy, and any unexpected emitted cues count as false positives. Deterministic-only runs have no semantic percentages. Console output includes `REMINDER_BENCHMARK_STATUS` before the existing end marker.

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

The final sustained 72-case run scored:

```text
exact cases: 72/72
cue precision: 100.0%
cue recall: 100.0%
schema field accuracy: 100.0%
exact evidence grounding: 100.0%
fuzzy resolution: 10/10
deterministic checks: 8/8
```

Targeted runs also passed dense/adversarial extraction at 10/10, precision boundaries at 12/12, feedback reprocessing at 8/8, and fuzzy resolution at 10/10. Foundation Models output is nondeterministic, so scores should be compared over complete runs rather than treated as permanent guarantees.

## Current 73-case revision verification

The updated parser passes all 12 deterministic checks, including the two named-game regression, two-day validity, upcoming source-event eligibility, exact named-event resolution, and rejection of an ungrounded `.log` summary artifact.

A targeted model-backed run of the new named-game case was attempted on both an existing and a fresh iOS 26.5 Simulator. Both failed inside the system model before producing content with `ModelManagerServices.ModelManagerError Code=1026`. No new model-quality score is recorded for this revision; the 72-case result above remains a historical baseline rather than a claim about the updated parser.

## Findings that changed the parser

- One large guided schema produced valid JSON-like shapes but mixed selector, recurrence, time, and duration values.
- Batch classification with opaque references caused decisions to leak between candidate events.
- Supplying an adjacent eligible action during draft extraction caused cross-action leakage; each focused action now gets an isolated model session.
- Compact action drafts and one-candidate boolean classifications were materially more reliable.
- Event scheduling needs the complete memo: an action near the end may refer to specific events named several sentences earlier.
- Explicit time, recurrence, relative duration, venue grounding, and obvious semantic conflicts are safer as deterministic validation.
- Feedback performs better when the model sees the transcript, current reminders, and ordered corrections in one coherent pass.
- A small deterministic gate improves both latency and precision, while ambiguous ownership, quotation, and correction cases still benefit from the model.
