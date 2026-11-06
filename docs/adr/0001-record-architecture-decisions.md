# 1. Record architecture decisions

Date: 2026-11-06

## Status

Accepted

## Context

Decisions with lasting structural effect get lost when they only live in
documents that describe the current state, such as `docs/outline.md`. Without
the reasoning, settled questions get reopened.

## Decision

We record architecture decisions as ADRs, following Michael Nygard's format.

- One file per decision in `docs/adr/`, named `NNNN-short-title.md`. Numbers are
  zero-padded, strictly increasing and never reused. The directory listing is
  the index.
- Sections: `# N. Title`, `Date:` (ISO 8601), `Status`, `Context`, `Decision`,
  `Consequences`. English, wrapped at 80 columns.
- ADRs are brief. Context gives only the background needed for the decision.
- Status values: `Proposed`, `Accepted`, `Rejected`, `Deprecated`,
  `Superseded by NNNN`.
- Accepted ADRs are not changed in substance. A changed decision gets a new ADR,
  and the old one's status becomes `Superseded by NNNN`.
- Scope: language, framework, persistence, URL schemes, security model, content
  pipeline, deployment, project-wide conventions.
- Other docs describe the current state and link to ADRs for the reasoning.

## Consequences

- Changing a decision costs a new file, on purpose.
- A structural change in a pull request brings its ADR in the same pull request.
- Two branches can collide on a number; the one that lands second renumbers.
