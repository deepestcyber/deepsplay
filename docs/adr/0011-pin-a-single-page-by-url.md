# 11. Pin a single page by URL

Date: 2026-11-06

## Status

Accepted

## Context

A repository can hold many pages. Working on one of them, or showing one on a
particular screen, needs a way to display a single page without rotation.

## Decision

A screen URL takes an optional `page` query parameter that pins it to one file:
`/?page=<path>` or `/c/<name>?page=<path>`.

- `<path>` is relative to the root of `screen.toml` (the repository, or the
  configured `subdir`), like page paths in `screen.toml`.
- Any file in the revision can be pinned, not only pages listed in
  `screen.toml`. The same path checks apply as for serving files (ADR 10).
- A pinned screen ignores rotation strategy, durations and weights.
- A new revision still reaches a pinned screen, which reloads the page.
- If the file does not exist in the current revision, the fallback page says
  so.

## Consequences

- One screen or browser tab can be pinned while others keep rotating, without a
  server restart.
- A pinned page can be set as a kiosk start URL.
- With a local repository (ADR 6), a page under development shows after each
  commit and poll.
- Anyone who can open a screen URL can pin it to any file of that revision.
  These files are served publicly anyway, so nothing new is exposed.
