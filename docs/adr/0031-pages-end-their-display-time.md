# 31. Pages end their display time

Date: 2026-11-11

## Status

Accepted

Amends [9](0009-rotation-in-the-browser.md),
[14](0014-page-parameters-defined-in-the-page.md) and
[25](0025-time-windows-and-overrides.md).

## Context

A page is shown for its `duration`. Some pages have a natural end that does
not match a fixed time: a simulation that runs until all its balls have
fallen, a video, a slideshow of a varying number of pictures. With a fixed
duration they either get cut off or sit on their final frame.

## Decision

A page can tell the shell that it is done; the shell then moves on. The
display time becomes an upper limit.

- `deepsplay.js` gets `Deepsplay.done()`. It sends a message to the parent
  window (`postMessage` to the page's own origin). Outside the shell (opened
  directly, in the catalog's preview and playground) nobody listens, and it
  has no effect.
- The shell accepts the message only from the frame that is visible, and
  only from its own origin. Messages from the hidden frame (still loading)
  or from a frame that is being replaced are ignored.
- A page has a minimum display time of 2 seconds, counted from the moment it
  is fully visible (after the crossfade). A `done()` before that is kept and
  takes effect when the 2 seconds are over. This keeps a page that calls
  `done()` at once from making the screen flicker.
- What happens on `done()`:
  - Rotation page: the next page is chosen as at the end of its display
    time (ADR 9, ADR 25).
  - If that is the same page (one active page, a pinned page, the
    `when_empty` page), it is loaded again in the other frame and
    crossfaded, so it starts fresh. Without `done()`, a single active page
    still stays on screen without reloading.
  - Override page: the override ends on this screen until its current
    window closes. Whatever is next comes back: a lower override that is
    still active, or the rotation with the interrupted page.
  - Interrupt page ([32](0032-interrupts.md)): the interrupt ends on this
    screen.
- `duration` and parameters with `from = "duration"` (ADR 16) are
  unchanged: the page gets its display time as the upper limit and may use
  it, e.g. to pace itself.
- Screens stay independent: `done()` affects only the screen whose page
  sent it.

## Consequences

- Pages with a natural end can be shown exactly as long as they need, up to
  their display time.
- How long a rotation takes is no longer known in advance.
- A page that calls `done()` too early is shown for 2 seconds at a time; a
  pinned page doing so reloads every 2 seconds.
- `done()` can be tried only on a screen or with a pinned page, not in the
  catalog.
- Pages without `done()` behave as before.
