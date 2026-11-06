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
  an iframe. Pages are not preloaded: when a page's time is up, the next one
  loads in a second, hidden iframe, so it starts running (scripts, animations,
  videos) only right before it is shown. The old page stays fully visible until
  the new one has loaded, they crossfade, and the old iframe is then cleared so
  it stops running.
- The repository chooses the strategy in `screen.toml`: `rotation =
  "sequential"` (default, pages in listed order) or `"random"`.
- Random rotation picks the next page weighted by its `weight` (float > 0,
  default 1.0), excluding the page currently shown when there is more than one.
  Weights are ignored in sequential rotation.
- A new plan pushed by the server is applied at the next page change.
- Screens are not synchronized with each other.
- Without a revision, the shell shows the built-in fallback page and switches to
  real content as soon as a revision is published.

## Consequences

- A screen that loses its connection keeps rotating with the plan it has.
- The server holds no per-screen timer state.
- Synchronized screens would need a new decision.
- With random rotation, screens on the same configuration show different pages.
- Because a page never follows itself, weights mean "more or less often", not
  exact shares: a dominant page shows at most every second time.
- Each page is an independent HTML document; the shell's styles do not reach
  into the iframes.
- The iframes take no pointer input (`pointer-events: none`), so the mouse
  always stays over the shell, whose `cursor: none` hides the pointer on every
  page. Pages get no mouse or touch input and no hover effects; interactive
  pages would need a new decision.
- A page is on screen a little longer than its duration, by the next page's
  load time. Animations that start on load run during the short fade-in.
