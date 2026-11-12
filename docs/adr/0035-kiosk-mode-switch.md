# 35. Kiosk mode can be switched off

Date: 2026-11-12

## Status

Accepted

Amends [5](0005-toml-for-host-config-and-screen-manifest.md) and
[9](0009-rotation-in-the-browser.md).

## Context

The shell hides the pointer (`cursor: none`) and its iframes take no pointer
input (ADR 9). On a display, that is what is wanted. While developing pages
in a desktop browser, the pointer vanishes over the screen, and pages cannot
be clicked, hovered or inspected with the mouse.

## Decision

`kiosk_mode` in `[server]` of the host configuration, a boolean, default
`true`:

- `true`: as before, the pointer is hidden and pages get no pointer input.
- `false`: the pointer shows, and the visible page of the rotation takes
  pointer input. The hidden frame, which loads the next page, stays
  click-through, so it cannot catch the mouse.

It applies to all screens of the host. A changed value reaches connected
screens with the reload of the host configuration (ADR 23). Without a usable
host configuration, screens stay in kiosk mode.

## Consequences

- Development configurations set `kiosk_mode = false`; displays leave it out.
- Pages that react to the mouse do so only with kiosk mode off. Displays
  still give pages no input; interactive pages remain a separate decision.
