# 36. Development overlay

Date: 2026-11-13

## Status

Accepted

Amends [5](0005-toml-for-host-config-and-screen-manifest.md) and
[9](0009-rotation-in-the-browser.md).

## Context

While developing pages, it helps to see on the screen which page is shown,
for how long it has been shown and how long it will stay, and to get to the
catalog and the status page quickly. Pages should not carry any of this:
they are shown on displays as they are, and each repository would need it
again.

The shell owns the document around the iframes of the rotation (ADR 9), so
it can draw on top of them. It also knows when a page appears, which one,
and for how long.

## Decision

`dev_overlay` in `[server]` of the host configuration, a boolean, default
`false`. With `true`, every screen shows a small overlay in its bottom left
corner, above the pages, drawn by the shell:

- a clock counting up from when the current page appeared, with its display
  time if it has one: a page's duration in the rotation, the rest of an
  override's window, the rest of an interrupt (`0:12 / 0:30`); pinned pages
  and the empty page count up only;
- the mode if it is not the rotation (`pinned`, `override`, `interrupt
  <name>`, `empty`);
- the page's path, linking to the page on its own;
- links to the catalog of the configuration and to the status page;
- a skip button that ends what is shown at once, as `Deepsplay.done()` from
  the page would (ADR 31), without its minimum display time: the next page
  of the rotation, the end of an override on this screen until its window
  closes, the end of an interrupt on this screen. It is off for pinned
  pages. The `S` key does the same, also while a page has the focus;
  not with modifier keys, in a text field, or when the page has handled
  the key itself.

The links open in the same tab, leaving the screen. A button collapses
the overlay to the clock and the skip button; the browser remembers it. Only the overlay takes
pointer input; the rest of the screen behaves as before (ADR 35).

The rotation hook tells the overlay what it shows with a `deepsplay:shown`
event on `window` at every page change, and again on `deepsplay:ask` from an
overlay that mounts later. The skip button sends `deepsplay:skip` to the
rotation hook. The overlay is outside the rotation's element, so
LiveView may add or remove it without touching the frames.

A changed value reaches connected screens with the reload of the host
configuration (ADR 23). There is no per-screen switch in the URL: a display
cannot be switched to show the overlay by its address.

## Consequences

- The overlay covers a small part of the page in the bottom left corner;
  collapsed, less of it.
- It is independent of `kiosk_mode`. With kiosk mode on, the pointer shows
  over the overlay only; development configurations usually switch both.
- Pages and screenshots taken inside a page do not contain the overlay.
