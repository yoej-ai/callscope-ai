"use client";

import { useState } from "react";

import { DisclosureChevron } from "@/components/playbook-controls";
import {
  publishedCriterionDisclosureState,
  type PlaybookCriterion,
} from "@/lib/playbooks.mjs";

export function PublishedCriteriaList({
  criteria,
}: {
  criteria: PlaybookCriterion[];
}) {
  const [expandedIds, setExpandedIds] = useState<Set<string>>(() => new Set());

  return (
    <ol className="published-criteria-list">
      {criteria.map((criterion) => {
        const open = expandedIds.has(criterion.id);
        const state = publishedCriterionDisclosureState(open);
        const detailsId = `published-criterion-details-${criterion.id}`;

        return (
          <li className={open ? "open" : undefined} key={criterion.id}>
            <div className="published-criterion-summary">
              <span className="published-criterion-position">
                {criterion.position}
              </span>
              <div className="published-criterion-copy">
                <strong>{criterion.name}</strong>
                <p>{criterion.description || "No description provided."}</p>
              </div>
              <span className="published-criterion-weight">
                {criterion.weight}%
              </span>
              <button
                aria-controls={detailsId}
                aria-expanded={state.detailsVisible}
                className="published-criterion-toggle"
                onClick={() => {
                  setExpandedIds((current) => {
                    const next = new Set(current);
                    if (open) next.delete(criterion.id);
                    else next.add(criterion.id);
                    return next;
                  });
                }}
                type="button"
              >
                <span>{state.label}</span>
                <DisclosureChevron open={state.detailsVisible} />
              </button>
            </div>

            {state.detailsVisible && (
              <div className="published-guidance-grid" id={detailsId}>
                <div>
                  <span>Pass guidance</span>
                  <p>{criterion.passGuidance || "No guidance provided."}</p>
                </div>
                <div>
                  <span>Fail guidance</span>
                  <p>{criterion.failGuidance || "No guidance provided."}</p>
                </div>
              </div>
            )}
          </li>
        );
      })}
    </ol>
  );
}
