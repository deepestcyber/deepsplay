# 9. Rotation in the browser

Date: 2026-11-06

## Status

Accepted

## Context

A screen cycles through the pages of a revision. Screens must keep working when
the connection to the server drops, and there is no requirement for screens to
show the same page at the same time.

## Decision

Rotation runs in the browser.

- A screen loads the shell, a LiveView that receives the plan: revision plus a
  list of page URLs with durations.
- A JavaScript hook in the shell cycles through the plan and shows each page in
  an iframe, optionally preloading the next one in a hidden iframe.
- A new plan pushed by the server is applied at the next page change.
- Screens are not synchronized with each other.
- Without a revision, the shell shows the built-in fallback page and switches to
  real content as soon as a revision is published.

## Consequences

- A screen that loses its connection keeps rotating with the plan it has.
- The server holds no per-screen timer state.
- Synchronized screens would need a new decision.
- Each page is an independent HTML document; the shell's styles and the
  `cursor: none` setting do not reach into the iframes.
