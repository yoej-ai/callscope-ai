# Human annotation workflow

No human annotations are committed in Phase 8B. The repository dataset contains
synthetic reference labels only.

For a future approved benchmark, each reviewer writes a separate append-only
JSONL file, for example:

```text
private-evals/sales_v1/reviewer-a.jsonl
private-evals/sales_v1/reviewer-b.jsonl
private-evals/sales_v1/adjudicated-v1.jsonl
```

Reviewer A and Reviewer B work independently and never edit each other’s file.
Disagreements remain intact. Adjudication creates a new record/file and does not
replace either source annotation. Git history is not a substitute for preserving
the original reviewer records.

Each line follows `eval_annotation.v1`:

```json
{
  "schema_version": "eval_annotation.v1",
  "case_id": "sales-en-001",
  "playbook_fixture_id": "sales_v1",
  "annotation_id": "sales-en-001-reviewer-a-v1",
  "labels": [
    {
      "criterion_id": "greeting",
      "outcome": "pass",
      "rationale": "The agent opens with a greeting and states the call purpose.",
      "evidence_turn_ids": ["t001"]
    }
  ],
  "reviewer": {
    "label_source": "human",
    "reviewer_alias": "reviewer-a",
    "reviewed_at": "2026-10-10T00:00:00Z",
    "notes": "Optional concise calibration note."
  }
}
```

The example documents format only and is not a claim that this case was reviewed
by a human. Use non-sensitive aliases, never reviewer names or email addresses.
Human records require a UTC review timestamp. Labels may be incomplete during
annotation; agreement output reports missing labels rather than silently
dismissing them.

Recommended workflow:

1. Freeze the dataset and playbook fixture versions.
2. Give each reviewer the same immutable case set and written label definitions.
3. Collect independent files without sharing interim labels.
4. Validate each file using the offline loader/tests before comparison.
5. Run agreement metrics and retain disagreements.
6. Calibrate label guidance without rewriting historical reviewer files.
7. Create a separately identified adjudication file if a final benchmark label
   is needed, linking its process in benchmark documentation.
8. Version any corrected/new benchmark as a new file; do not silently overwrite.

Real call content must not be committed by default. Before using it, establish
approved consent, redaction, retention, access, and deletion controls.
