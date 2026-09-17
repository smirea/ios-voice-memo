# Event reminder model

Event reminders turn forward-looking statements in an event-attached voice memo into focused context for later calendar events. They deliberately exclude general tasks without an event target; those belong in a dedicated task manager.

## Product principles

- Extract any number of useful reminders, including none. Never fill a quota.
- Prefer omission over an irrelevant reminder.
- Keep every reminder grounded in an exact source excerpt.
- Let the model interpret language, but keep dates, recurrence, event identity, expiration, and delivery deterministic.
- Never let the model invent calendar identifiers.
- Preserve user corrections and manual removals when a note is reprocessed.
- Keep Calendar access read-only.
- Store reminder rules with their source note so local storage and its iCloud Drive export remain complete.

## Model

A reminder is the composition of an action, an event selector, an occurrence policy, validity, and presentation settings. These are independent dimensions rather than separate one-time, recurring, and fuzzy reminder types.

```text
EventReminderRule
  id
  text
  motivation
  evidence
  selector
  occurrencePolicy
  createdAt
  expiresAt
  leadTimeOverride
  resolvedOccurrence
  consumedAt
  sourceFeedbackID
```

`text` is a concise imperative such as “Bring electrolytes.” `motivation` is a short grounded explanation such as “You were tired after the gym.” `evidence` is the supporting excerpt from the original memo or a later correction, shown when the user inspects the rule.

### Event selectors

`series`
: Targets a real recurring series or a stable logical series derived from its source event. EventKit’s external identifier is preferred for recurring events. Cached calendar, title, and time details provide fallbacks when identifiers change.

`fuzzy`
: Describes an event semantically and adds deterministic constraints such as a time-of-day bucket. The model evaluates bounded calendar candidates after those constraints are applied.

There is intentionally no unbound selector. A statement that cannot be associated with an event produces no reminder.

### Occurrence policies

`nextMatch`
: Pins the first matching future occurrence and becomes consumed after that occurrence ends. Consumption records retirement, not proof that an alert was delivered or seen. Reprocessing cannot move the pin or reset consumption, and a missing calendar occurrence never redirects the cue to another event.

`everyMatch`
: Delivers at every matching event until it expires or is removed.

### Validity

The parser may return an indefinite duration or a relative value in days, weeks, or months. App code resolves relative values against the recording date and persists the resulting absolute expiration date. Expired rules never produce occurrences.

### Presentation

Rules inherit the global lead time unless a future manual editor supplies an override. The default is one hour before the event. A reminder occurrence becomes stale when its event ends.

The number of extracted reminders is never capped. System surfaces can show a short prefix plus the remaining count, with the full list available in the app.

## Stored and derived data

`EventReminderRule`
: Persistent and user-editable. Stored on the source `JournalEntry`.

`ReminderFeedback`
: Persistent transcript or manual-removal correction stored on the source entry. All feedback is included in later reminder reprocessing.

`EventReminderOccurrence`
: Transient materialization of one active rule against one future calendar event. Rebuilt whenever calendar data or reminder rules change.

`ReminderMatchExample`
: A compact historical or upcoming example produced while evaluating a fuzzy selector. Examples explain the rule’s current behavior but are not treated as user-confirmed training data.

Calendar changes update derived occurrences and presentation. A proven current version of a pinned occurrence refreshes its stored snapshot before its end is checked; once consumption is saved it never reverses. Detached events whose start changed need provable occurrence identity before a pin can be refreshed.

## Parsing

Reminder parsing is separate from title and summary generation. The parser receives:

- the full transcript;
- the recording date;
- the attached source event;
- the current reminder rules and all prior feedback during reprocessing.

The on-device model performs two compact semantic stages instead of producing an entire rule in one large schema:

1. When the complete transcript, existing reminder set, and ordered corrections fit, read them in one request. Otherwise walk every original passage and correction in order, rebuilding candidates from the source; each later passage revises every accumulated candidate shard before adding new actions. Return every final action with a motivation and exact supporting excerpt. There is no maximum reminder count.
2. Resolve clear named or attached targets directly from their grounded context. When semantic interpretation is still needed, use a separate compact scheduling request per action; requests share one on-device response permit, and recording preempts both queued and active analysis.
3. Derive attached-series versus fuzzy targeting, next versus every policy, time of day, and relative validity from the grounded schedule context.
4. Reject ungrounded actions and venues. At the saved-result boundary, reconcile app-owned identity and retirement state, apply manual removals deterministically, and deduplicate exact equivalent actions.

The parser follows these rules:

- Extract only the speaker’s intention, preparation, commitment, or request to their future self.
- Do not turn observations, another person’s behavior, or generic advice into reminders.
- Do not produce a reminder without an attached-event or fuzzy-event target.
- Preserve concrete details such as names, colors, time of day, place, and duration.
- Deduplicate equivalent actions.
- Treat ambiguous corrections conservatively.
- Treat corrections as authoritative and apply them in order.

The decomposition is intentional. Simulator evaluation showed that the system model was accurate on compact schemas but mixed fields and opaque references when action, selector, recurrence, duration, and batches of identifiers shared one generated type. The extraction pass preserves chronological corrections, while the second pass keeps the scheduling schema small. Long passages receive bounded preceding event references with their original source positions. Deterministic fields make corrections such as “evening, not morning” stable across model versions.

Every native request budgets its instructions, full prompt, generated schema, and output reserve against the runtime context window. Oversized extraction passages split at safe text boundaries; context failures have finite smaller-passage retries. Scheduling uses the whole memo when it fits and otherwise uses the action's original evidence, local context, and relevant preceding targets. An oversized required context or fuzzy-event candidate fails explicitly instead of silently dropping text. A failed passage preserves the previous completed reminder set rather than publishing a partial set.

Guided generation guarantees the shape of a model result, not its semantic correctness. App validation rejects empty action or motivation text, noncontiguous evidence, action text that is not substantially grounded in that evidence, hallucinated venues, invalid durations, and reminders without an event target. Generic references such as “the game” use the complete memo when it fits, or relevant preceding named-event context with original source positions for long inputs. Covering every source range does not guarantee that the model preserves every relevant fact.

If the system language model is unavailable or parsing fails, the app produces no new reminders rather than using a speculative heuristic.

## Identity and retirement

Generated rules propose content; an atomic per-note commit preserves established UUIDs, creation dates, one-time pins, consumption, and manual lead-time overrides. Identity matching uses fixed-locale complete words and equivalent selectors. A shared source sentence alone cannot merge distinct actions. Uncertain regenerated wording that may refer to a retired action is omitted rather than given a fresh cue.

Omitted and manually removed identities remain in a per-note archive, deduplicated by UUID and included in the complete JSON export. Reappearing rules recover their earlier state after a restart. Known manual removals veto that identity; legacy removals without a recoverable identity use complete action words rather than noun subsets.

Only an unambiguous new voice instruction can establish a fresh generation: its exact contiguous evidence must occur uniquely in that feedback and be absent from the original transcript and other feedback. The source feedback ID and processed feedback IDs are saved with the reminder result, so reprocessing the same correction cannot repeatedly re-arm it. Legacy saved feedback starts as already processed. Original evidence preserves internal whitespace and line breaks.

## Event resolution

Resolution happens after parsing:

1. Load a bounded range of included-calendar events.
2. Discard canceled events, expired rules, and occurrences that started at or before the reminder was created. An attached source event remains eligible when the memo was recorded before it.
3. Require each scheduled occurrence, including a current pin, to start at or before the reminder's expiration. The expiration boundary is inclusive; no expiration means indefinite validity. Retain ongoing eligible occurrences through their end while the rule remains active, and apply time-of-day constraints.
4. Match series using stored identifiers and cached fallbacks.
5. Resolve specific multiword event names directly only as complete, ordered name phrases in candidate titles. Ignore case, diacritics, punctuation, and surrounding title decoration; preserve words inside the name. “Blood on the Clock Tower” is an explicit spelling alias for “Blood on the Clocktower.” Shared word prefixes only permit semantic evaluation, never direct acceptance.
6. Require a lexical event-type anchor, then ask the model to classify each remaining fuzzy candidate independently.
7. Treat uncertain completed fuzzy classifications as nonmatches. Unavailable or failed classification remains incomplete, preserves known deterministic matches, and does not create a negative example or choose a new one-time pin past an unknown candidate.
8. Materialize either the first match or every match according to the occurrence policy. A one-time pin resolves only that same occurrence; if it is missing, retain the pin and produce no substitute. Refresh a provably identical snapshot before checking its end, and save consumption after it ends. Consumed cues never materialize, even if generated policy wording changes.

Resolution reads committed notes and excludes notes with pending source edits. A source revision and the original reminder set guard each atomic pin/example save; unrelated location changes do not invalidate it. A failed pin save prevents delivery for that note and can be retried. Obsolete results are discarded after relevant source, calendar, or delivery-setting changes.

Recurring EventKit events prefer their external identifier because it is shared by occurrences. Calendar identifier, normalized title, and approximate start time form the fallback. Separately-created events such as Meetup imports are handled through fuzzy matching.

Fuzzy evaluation receives only the rule and one supplied candidate event with its title, calendar, start, end, location, and notes. Future occurrences outside the validity window, time constraints, and explicit venue constraints are filtered before the model. Ended historical events remain available as matching examples, but cannot become scheduled occurrences. An out-of-window pin is retained without scheduling a substitute. One candidate per two-value decision avoids the reference mixing observed when the on-device model classified batches.

Morning, afternoon, and evening are app-defined local-time buckets. The model chooses a named bucket; it does not generate arbitrary clock ranges.

## Review and correction

The source note shows reminders immediately below the summary with no section heading. Tapping a row reveals its evidence, motivation, and fuzzy match examples; a native trailing swipe removes it immediately. With no reminders, the section is only the **No reminders: Add feedback** action.

Removing a reminder archives its identity, removes the visible rule, and adds a manual-removal feedback record. This prevents a later reprocessing pass from recreating the same reminder from the original transcript.

“Add feedback” records a short audio correction, transcribes it, deletes the temporary audio, and re-evaluates reminders with:

- the current reminder set;
- previous feedback;
- the new feedback.

Manual removals are reapplied deterministically, so reprocessing cannot silently resurrect a reminder the user removed. Other additions, replacements, and corrections pass through the same complete-source grounded parser; for long inputs a final correction can remove or replace candidates from any earlier passage. Feedback reprocessing changes reminders only; it does not rewrite the note title, summary, or transcript.

Full note reprocessing retranscribes the saved audio, regenerates the title and summary, then extracts reminders while reapplying every stored feedback correction and manual removal. Previously completed results remain available until each replacement stage succeeds.

## Live Activity

Active reminder occurrences schedule a standard Live Activity to begin at the configured lead time. It presents the event title and available reminder text, then links to the source note for the full list and feedback controls.

The activity uses the event end as its stale date. The app ends obsolete, removed, or expired activities during its next calendar refresh. Scheduled activities are maintained over a rolling near-term horizon because iOS applies a device-dependent limit and scheduled activities count toward it.

The recording Live Activity has higher relevance than an event-reminder activity when both exist.

Settings provide:

- a master event-reminders toggle;
- a Live Activities toggle;
- a global lead-time picker.

Rules remain stored when delivery is disabled. One owned reconciliation serializes activity updates, removals, and requests; a canceled or replaced pass cannot publish after a newer pass. Derived pin-save errors retire when reminders are disabled, while unsaved source edits remain retryable.

## Evaluation

The Settings screen includes the repeatable benchmark described in [`reminder-model-evaluation.md`](reminder-model-evaluation.md), using the same deterministic reconciliation as saved reminder results. Model scores are kept separate from this contract because they describe observed quality for one OS/model version, not guaranteed product behavior.

## Future manual editing

A manual editor can create and modify the same `EventReminderRule` structure. It should not introduce a parallel representation. Future positive and negative example corrections can be stored separately from model-produced previews and supplied as few-shot context during fuzzy classification.
