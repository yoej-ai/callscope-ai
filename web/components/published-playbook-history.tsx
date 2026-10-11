"use client";

import { useState } from "react";

import { DisclosureChevron } from "@/components/playbook-controls";
import {
  publishedCriterionDisclosureState,
  versionHistoryDisclosureState,
  type PlaybookCriterion,
  type PlaybookVersion,
} from "@/lib/playbooks.mjs";

function formatPublishedDate(value: string | null) {
  if (!value) return "Date unavailable";
  return new Intl.DateTimeFormat("en-AU", { dateStyle: "medium" }).format(
    new Date(value),
  );
}

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

export function PreviousVersionHistory({
  versions,
}: {
  versions: PlaybookVersion[];
}) {
  const [open, setOpen] = useState(false);
  const [expandedIds, setExpandedIds] = useState<Set<string>>(() => new Set());
  const state = versionHistoryDisclosureState(open, versions.length);
  const contentId = "previous-playbook-versions";

  if (state.count === 0) return null;

  return (
    <section className={`previous-version-history ${state.open ? "open" : ""}`}>
      <button
        aria-controls={contentId}
        aria-expanded={state.open}
        className="version-history-trigger"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <DisclosureChevron open={state.open} />
        <span className="version-history-copy">
          <span className="eyebrow">Version history</span>
          <strong>
            {state.count} previous {state.count === 1 ? "version" : "versions"}
          </strong>
          <small>{state.label}</small>
        </span>
      </button>

      {state.contentVisible && (
        <div className="previous-version-list" id={contentId}>
          {versions.map((version) => {
            const versionOpen = expandedIds.has(version.id);
            const detailsId = `previous-version-${version.id}`;

            return (
              <article className="previous-version-entry" key={version.id}>
                <div className="previous-version-summary">
                  <div>
                    <strong>Version {version.versionNumber}</strong>
                    <span>
                      Published {formatPublishedDate(version.publishedAt)}
                    </span>
                  </div>
                  <span className="history-read-only">Read-only</span>
                  <button
                    aria-controls={detailsId}
                    aria-expanded={versionOpen}
                    className="previous-version-toggle"
                    onClick={() => {
                      setExpandedIds((current) => {
                        const next = new Set(current);
                        if (versionOpen) next.delete(version.id);
                        else next.add(version.id);
                        return next;
                      });
                    }}
                    type="button"
                  >
                    <span>{versionOpen ? "Hide version" : "View version"}</span>
                    <DisclosureChevron open={versionOpen} />
                  </button>
                </div>

                {versionOpen && (
                  <div className="previous-version-details" id={detailsId}>
                    <p>
                      This immutable definition preserves the criteria used by
                      its historical evaluations.
                    </p>
                    <PublishedCriteriaList criteria={version.criteria} />
                  </div>
                )}
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
