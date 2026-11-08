# 30. Seconds in time windows

Date: 2026-11-08

## Status

Accepted

Amends [25](0025-time-windows-and-overrides.md).

## Context

Time windows (ADR 25) are minute-precise. For pages that is enough: a page's
window is only checked when the rotation switches. Overrides interrupt the
rotation at their start, and some need to start or end at a given second,
e.g. a countdown that must end exactly at midnight.

## Decision

Times in windows may have seconds: `HH:MM` or `HH:MM:SS`.

- `from` and `until`: `"11:59:30"`; `24:00` and `24:00:00` are both the end
  of the day.
- `start` and `end`: `"2027-03-04 10:00:15"` (also with `T`).
- `HH:MM` is still valid and means `HH:MM:00`. The same format applies to
  pages and overrides.
- Internally, daily times are seconds of the day, on the server and in the
  browser; the plan sent to screens carries `from` and `until` in seconds.
  The shared test cases cover seconds.
- Screens check overrides at every full second while any window of the plan
  has seconds, otherwise at every full minute as before.
- The remaining time of an override's window (for `from = "duration"`) is
  computed from the next boundary of its windows, to the second.
- The catalog shows windows as written.
- A screen that reconnects with an outdated shell (`app.js`, `app.css`)
  loads the page again, so it never reads a plan in a form it does not know.

## Consequences

- Overrides can start and end at a given second.
- Second-precise windows are only as precise as the screens' clocks: screens
  should keep their time synchronised (NTP), otherwise they switch at
  slightly different moments.
- The plan's `from` and `until` change their unit, so a screen must not keep
  running an older shell: a screen that reconnects with outdated `app.js` or
  `app.css` (LiveView's `static_changed?`) now loads the page again. Before,
  screens kept the old shell until restarted.
