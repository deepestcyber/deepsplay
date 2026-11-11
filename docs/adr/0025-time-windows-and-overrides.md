# 25. Time windows and overrides

Date: 2026-11-07

## Status

Accepted

Amends [5](0005-toml-for-host-config-and-screen-manifest.md) and
[9](0009-rotation-in-the-browser.md).

Amended by [29](0029-disabled-manifest-entries.md): overrides can be switched
off with `enabled = false`.

Amended by [30](0030-seconds-in-time-windows.md): times in windows may have
seconds.

Amended by [31](0031-pages-end-their-display-time.md): `Deepsplay.done()` on an
override page ends the override on that screen until its window closes.

Amended by [32](0032-interrupts.md): interrupts replace overrides of equal or
lower priority, and overrides opening during an interrupt replace it the same
way; overrides among themselves are unchanged.

## Context

Some pages belong to certain times only: a night page from 22:00 to 06:00,
an announcement for one event, a page on the 13th to 15th of each month.
Other pages must interrupt the rotation for a while: a fire drill, the lunch
menu at noon. Today every page of a manifest is always in the rotation, and
nothing interrupts it. Rotation runs in the browser (ADR 9), so each screen
can decide at every page change which pages are active.

## Decision

Manifest page entries get optional **time windows** in a field `when`; a
manifest gets `when_empty` for times when no page is active, and a list of
**overrides** that interrupt the rotation during their time windows.

The time window format:

- `when` is one window (a table) or a list of windows. A page is active if
  any of its windows matches; a window matches if all of its fields match.
  A page without `when` is always active.
- Fields of a window, all optional:

  | Field | Meaning |
  | --- | --- |
  | `start`, `end` | one continuous period: `YYYY-MM-DD` or `YYYY-MM-DD HH:MM` (also with `T`); either may be left out for an open end |
  | `dates` | days it applies: `YYYY-MM-DD`, `MM-DD` (every year) or `DD` (every month); ranges with `..` (`"12-20..12-26"`, `"13..15"`); or a list of these |
  | `days` | weekdays: `mon` to `sun`, a list or a range (`"mon-fri"`) |
  | `from`, `until` | daily time window `HH:MM`; `until` before `from` runs overnight; `until = "24:00"` is the end of the day |

- `start`/`end` limit a window to a period; `dates`, `days`, `from` and
  `until` describe a window that repeats within it.
- Dates are always ISO (`YYYY-MM-DD` and its parts), times always 24-hour
  `HH:MM`. Times are the screen's local time. A start is included, an end
  excluded.
- Invalid windows reject the revision, like other manifest errors.

Examples:

```toml
[[page]]
path = "night.html"
when = { from = "22:00", until = "06:00" }

[[page]]
path = "event.html"
when = { start = "2027-01-02 04:00", end = "2027-01-03 10:00" }

[[page]]
path = "early.html"
when = { dates = "2027-01-02..2027-01-03", from = "04:00", until = "10:00" }

[[page]]
path = "payday.html"
when = [{ dates = "13..15" }, { dates = "12-24", until = "14:00" }]
```

Rotation:

- At each page change, the screen picks the next page among the pages active
  at that moment: in sequential rotation the next active page after the
  current one, in random rotation weighted among the active ones, still
  avoiding the same page twice in a row where possible.
- A page whose window closes while it is shown finishes its display time.
- With one active page, it stays on screen without reloading; the choice is
  made again after each display time.
- With no active page, the manifest's `when_empty` applies: `"black"`
  (default) shows a black screen, a page path shows that page (it need not
  be in the rotation). The screen checks again every minute and at the next
  window boundary.
- Pinned pages (`?page=`) ignore time windows.

Overrides:

```toml
[[override]]
path        = "fire-drill.html"
when        = { start = "2027-03-04 10:00", end = "2027-03-04 10:15" }
priority    = 10

[[override]]
path = "lunch.html?menu=today"
when = { days = "mon-fri", from = "11:45", until = "12:00" }
```

- `[[override]]` entries have `path` (with query) and `when`, both required,
  and optionally `priority` (an integer, default 0), `description` and
  `uses`. Invalid entries reject the revision.
- Each screen works out from the windows when the next override starts or
  ends and acts at that moment; the result is the same on every screen with
  a correct clock.
- When an override's window opens, it interrupts whatever is shown at once
  (with the usual crossfade) and the rotation pauses.
- If several are active, the highest `priority` wins; with equal priority,
  the first in the list. A higher one starting during a lower one takes
  over; when it ends and the lower one is still active, the lower one comes
  back.
- When no override is active any more, the rotation continues with the
  interrupted page, shown again with a fresh display time (pages cannot
  resume their state).
- An override is shown also when no rotation page is active (before
  `when_empty`).
- Overrides get added parameters like pages (ADR 16); a parameter with
  `from = "duration"` gets the remaining time of the window.
- Pinned pages (`?page=`) ignore overrides.

The catalog shows each rotation entry's windows and whether it is active
now, and lists the overrides with windows, priority and whether one is
active now.

## Consequences

- Rotations can follow the day, the week and events without editing the
  manifest at the right moment.
- Screens need a correct clock and time zone; screens in different time
  zones follow their own. A server-wide time zone can be added later.
- The format is small and our own; fields can be added when needed (e.g.
  months, holidays).
- The rotation code in the browser has to handle a changing set of pages,
  including one and none, and interruptions by overrides.
- Announcements reach every screen of a configuration at the same time,
  without editing the manifest at the right moment; a pinned screen does not
  get them.
