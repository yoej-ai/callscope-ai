# CallScope offline evaluation foundation

This directory contains deterministic, repository-only fixtures and tooling for
evaluating a **future** playbook-driven CallScope scorecard. It does not run a
model, score production calls, access Supabase, or measure current AI accuracy.

## Product and provenance boundary

The committed Sales dataset is entirely synthetic. Its labels have
`label_source: synthetic_reference`; they are development references written to
exercise validation and metrics, **not human-reviewed benchmark labels**. They
must not be presented as real-world accuracy evidence or a marketing benchmark.

A real benchmark requires independent human annotation, calibration, preserved
disagreements, and adjudication. Until that exists and real Phase 9A predictions
are evaluated against it, do not claim that “AI accuracy is X%.”

Never commit real calls by default. Any future real evaluation data requires an
approved privacy, consent, redaction, access, retention, and deletion process.
It must not contain credentials, session data, private customer identifiers, or
unredacted production transcripts.

## Files

- `playbooks/sales_v1.json` is a stable evaluation fixture, not a Supabase row.
- `datasets/sales_v1.jsonl` contains 30 synthetic calls: 10 English (`en`),
  10 Filipino (`fil`), and 10 mixed English-Filipino (`en-fil`).
- `annotations/README.md` defines the append-only human review workflow.
- `worker/callscope_worker/evaluation.py` owns validation and deterministic
  metrics. It has no network or production-worker dependency.
- `worker/callscope_worker/evaluation_cli.py` provides local commands.

## Canonical Sales playbook

The stable fixture identifier is `sales_v1`. Criterion identifiers are fixture
identifiers only and must never be treated as production database UUIDs.

| Position | Criterion ID | Name | Weight |
| ---: | --- | --- | ---: |
| 1 | `greeting` | Greeting | 10 |
| 2 | `discovery` | Discovery | 25 |
| 3 | `qualification` | Qualification | 20 |
| 4 | `objection_handling` | Objection Handling | 15 |
| 5 | `closing` | Closing | 15 |
| 6 | `clear_next_step` | Clear Next Step | 15 |

The weights total exactly 100 and structurally mirror Phase 8A criterion
semantics without coupling the evaluation data to a tenant or workspace.

## Gold-label contract

`eval_case.v1` supports four outcomes without collapsing uncertainty:

- `pass`: observable transcript evidence supports that the criterion was met.
- `fail`: the criterion applied and observable evidence supports that it was
  not met.
- `not_applicable`: the criterion genuinely did not apply to the call.
- `insufficient_evidence`: missing, incomplete, or ambiguous transcript data
  prevents a confident label.

Each label has a fixture criterion ID, concise observable rationale, and zero
or more valid transcript turn references. Optional per-label `annotation`
metadata is supported when a label has provenance different from the enclosing
case/annotation record. Rationales must summarize evidence only; never record
chain-of-thought or hidden reasoning.

Each case has a stable case ID, explicit provenance and synthetic flag,
scenario, language, bounded transcript turns, complete criterion labels,
reference score, review-needed flag, and annotation metadata. Speaker roles are
optional fixture context; evaluation never assumes production diarization.

## Reference score

The deterministic helper uses the playbook weights:

1. `pass` earns the full criterion weight.
2. `fail` earns zero and remains in the eligible denominator.
3. `not_applicable` is excluded from the denominator.
4. `insufficient_evidence` is excluded and sets `review_needed`.
5. `score = 100 × passed eligible weight ÷ total eligible weight`, rounded to
   two decimals with decimal half-up rounding.
6. With no eligible `pass`/`fail` weight, score is `null`, the result is
   incomplete, and review is required.

This score is an offline reference calculation only and is never persisted to
production.

## Validate locally

From `worker/` with the existing development environment active:

```powershell
python -m callscope_worker.evaluation_cli `
  --playbook ../evals/playbooks/sales_v1.json `
  --dataset ../evals/datasets/sales_v1.jsonl `
  validate
```

Invalid files return a non-zero exit status and a safe error code. Output is
sorted JSON and contains no generated timestamps.

## Evaluate future predictions

Prediction files use one JSON object per line with this closed contract:

```json
{"schema_version":"eval_prediction.v1","case_id":"sales-en-001","playbook_fixture_id":"sales_v1","criteria":[{"criterion_id":"greeting","outcome":"pass"}],"overall_score":90.0,"review_needed":false}
```

Criteria may be omitted to measure coverage, but malformed, duplicate, unknown,
or extra case/criterion values are rejected explicitly. A prediction example is
schema documentation only; it is not a claimed model result.

```powershell
python -m callscope_worker.evaluation_cli `
  --playbook ../evals/playbooks/sales_v1.json `
  --dataset ../evals/datasets/sales_v1.jsonl `
  evaluate --predictions path/to/predictions.jsonl
```

The report includes exact criterion accuracy, per-criterion and per-language
accuracy, confusion counts, macro precision/recall/F1, score MAE where scores
are comparable, review-needed accuracy, coverage, and missing counts.

## Compare reviewers

Follow `annotations/README.md`, then run:

```powershell
python -m callscope_worker.evaluation_cli `
  --playbook ../evals/playbooks/sales_v1.json `
  --dataset ../evals/datasets/sales_v1.jsonl `
  agree `
  --reviewer-a ../private-evals/sales_v1/reviewer-a.jsonl `
  --reviewer-b ../private-evals/sales_v1/reviewer-b.jsonl
```

Agreement reports preserve missing labels, segment by criterion and language,
and return a truthful null status when Cohen’s kappa is mathematically
undefined. Real/private annotation paths above are illustrative and should
remain outside the repository unless separately approved and sanitized.
If only one reviewer file exists, omit `--reviewer-b`; the command returns an
explicit `insufficient_reviewers` status instead of inventing agreement.

## Validation and security bounds

Validation rejects unsupported versions/outcomes/languages, duplicate IDs,
unknown criteria, blank or oversized transcripts, malformed or duplicate turn
IDs, nonexistent evidence references, inconsistent provenance, invalid reviewer
metadata, invalid or inconsistent scores/review flags, unbounded structures,
recognizable credential/private-key patterns, email-like identifiers, and long
phone/account-number-like digit sequences. Files are bounded to 10 MB,
datasets to 10,000 cases, transcripts to 500 turns and 1,000,000 characters,
individual turn text to 20,000 characters, rationale to 500 characters, and
notes to 1,000 characters.

The sensitive-data scanner is a defense-in-depth safeguard, not complete data
loss prevention (DLP). Review and sanitize every dataset before it enters the
repository; passing validation does not prove that content is non-sensitive.

The tooling uses only Python’s standard library, makes no network calls, does
not execute dataset content, and has no external side effects beyond reading
the explicitly supplied files and writing its report to stdout.
