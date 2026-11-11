# Reactive pages

Status: in progress (2026-11-11)

Two ways for what is on screen to react to events instead of a fixed
schedule: a page ends its own display time when it is done
([ADR 31](../adr/0031-pages-end-their-display-time.md)), and backends or
other systems put a page on all screens of a configuration at once
([ADR 32](../adr/0032-interrupts.md)).

Background: [ADR 9](../adr/0009-rotation-in-the-browser.md) (rotation in the
browser), [ADR 25](../adr/0025-time-windows-and-overrides.md) (overrides),
[ADR 26](../adr/0026-sidecars.md) (backends),
[ADR 16](../adr/0016-default-parameters-per-configuration.md) (parameters),
[pages.md](../pages.md).

Status values: `open`, `in progress`, `done`.

| # | Part | Status |
| --- | --- | --- |
| 1 | `Deepsplay.done()` and the shell | done |
| 2 | Manifest: `[[interrupt]]` | open |
| 3 | Tokens: host configuration and backends | open |
| 4 | Trigger route and broadcast | open |
| 5 | Shell: interrupts next to overrides | open |
| 6 | Catalog and status page | open |
| 7 | Docs | open |

Decisions taken in discussion (2026-11-11), recorded in the ADRs:

- `done()` on an override ends it on that screen until its window closes.
- Minimum display time before `done()` takes effect: 2 seconds, fixed.
- Triggers authenticate with a bearer token: generated for each backend
  start, from a host secret for other systems.
- Interrupts are events: shown on the screens connected when they are
  triggered, never caught up after a reconnect or reload, and gone once
  they are off a screen.
- An incoming interrupt replaces what is shown if its priority is equal or
  higher, otherwise it is ignored. An override opening during an interrupt
  replaces it the same way; the interrupt is dropped, a replaced override
  comes back if its window is still open.
- Overrides among themselves keep ADR 25: priority, then list order.
- An interrupt triggered while shown starts fresh.
- The trigger answer reports how many screens got the event.
- Triggers may pass parameters; they are checked against the page's
  definitions.
- Interrupts reach all screens of a configuration.

Order: part 1 stands alone and can ship first. Parts 2 to 6 build on it,
since interrupt pages end with `done()`.

## 1. `Deepsplay.done()` and the shell

Status: done

- `assets/lib/deepsplay.js`: `done()` posts `{deepsplay: "done"}` to
  `window.parent` with `location.origin` as target. No-op when
  `window.parent === window`. Part of `v1` (a compatible addition); the
  version archive gets it with the next release.
- `shell_live.ex` hook: one `message` listener on `window`. Accept only if
  `event.origin === location.origin` and `event.source` is the
  `contentWindow` of the visible frame; ignore anything else.
- Minimum display time: remember when the visible frame became fully
  visible (end of the crossfade). A `done()` earlier than 2 s after that is
  stored and applied at the 2 s mark. A new page resets it.
- On `done()`, by what is shown:
  - rotation page: same path as the end of the display time (`next()`),
    with the existing timer cleared;
  - same page chosen again (one active page, pinned, `when_empty` page):
    load it into the other frame and crossfade. This needs a "force reload"
    path next to the current "keep it when it's the same" shortcut;
  - override: add it to a per-screen "dismissed" set with the end of its
    current window; recompute what is shown (part 5 extends this to
    interrupts). Entries expire when the window closes;
  - black screen: nothing to do.
- Tests (Node, `schedule_test.mjs` or a new shell test): the dismissal
  bookkeeping as pure functions in `schedule.js` where possible. The
  message handling itself needs a browser; check it with a pinned test page
  and a rotation of two pages, as for the 0.4.0 checks.

Built:

- `Deepsplay.done()` in `assets/lib/deepsplay.js`, with Node checks in
  `test/js/deepsplay_test.mjs`.
- `schedule.js`: `currentOverride/3` takes the dismissals; `dismiss/3` and
  `overrideKey/1` keep them, keyed by URL, windows and priority so a new
  plan with the same override keeps it dismissed. Node checks in
  `schedule_test.mjs`.
- Shell hook: `message/1` filters (origin, visible frame, not while a new
  page loads, one pending `done()` at a time), `done/0` acts by mode,
  `showNext(true)` loads the same page again. `shownAt` is set at the swap
  plus the crossfade; `display/2` and `blank/0` cancel a pending `done()`.

Checked in headless Chromium against a production build (2026-11-11):

- rotation: a page calling `done()` after 3 s was shown about 3 s, a page
  without it its full 5 s, a page calling `done()` at once 2.5 s (2 s
  minimum plus the crossfade);
- pinned page with `done()` after 3 s: reloaded in the other frame every
  3 s;
- override with `done()` after 3 s: started on its second, ended after the
  `done()`, the rotation continued with the interrupted page, and the
  override did not come back during the rest of its window.

Not done yet: pages.md and the CHANGELOG (part 7).

## 2. Manifest: `[[interrupt]]`

Status: open

- `Deepsplay.Screen`: `@interrupt_fields` with `name` (required, upstream
  name rule), `path` (required, with query, file must exist), `duration`
  (required), `priority` (default 0), `description`, `uses`, `enabled`.
- New struct `Deepsplay.Screen.Interrupt`. The screen gets `interrupts`;
  disabled ones go to `disabled` like pages and overrides (ADR 29).
- Duplicate names are an error. `page = false` files get the usual warning.
- Tests in `screen_test.exs`: valid entries, missing fields, duplicates,
  bad names, disabled.

## 3. Tokens: host configuration and backends

Status: open

- Host configuration: `interrupt_token = "<secret name>"` per `[[config]]`;
  error if the secret is not defined (as `credential`). Picked up on reload
  (ADR 23).
- `Deepsplay.Backend`: create a random token (32 bytes, URL-safe base64) at
  each start, pass it as `DEEPSPLAY_TOKEN`, and register it for the
  configuration while the process runs. With named backends (dev-0006),
  each backend gets its own.
- A small module that answers "is this token valid for configuration X"
  (backend tokens plus the host secret), compared with
  `Plug.Crypto.secure_compare/2`.
- Warning on the status page when a manifest has interrupts but the
  configuration has neither a backend nor `interrupt_token`.

## 4. Trigger route and broadcast

Status: open

- Route `POST` and `DELETE /c/:name/interrupts/:interrupt`, a controller
  outside the browser pipeline (no CSRF, no session), with a plug for the
  bearer token.
- Parameters: from the query (at most 2 KB), checked with the existing
  parameter code (`PageParams`) against the page's definitions and its
  `uses`; unknown or invalid ones give `422` with the reasons.
- Page URL: built like an override's (ADR 16 levels), with the trigger's
  parameters on top and `from = "duration"` set to the interrupt's
  duration.
- Broadcast on a PubSub topic per configuration, next to the one shells
  already subscribe to for revisions (`Revisions.subscribe/1`). `ShellLive`
  pushes `interrupt` (name, URL, priority, duration in ms) or
  `interrupt_end` (name) to its hook. Nothing is pushed on mount.
- Screen count: a `Registry` (or `Phoenix.Tracker`) of connected shells
  per configuration, with whether they are pinned. The `202` answer is
  `{"screens": n, "duration": ms}`, `n` counting connected shells that are
  not pinned. `DELETE` answers the same way.
- Last trigger per interrupt (time, answer, screens) in a small process or
  ETS table, for the status page and the rate limit (`429` for the same
  name within 2 s). Nothing else is kept; a restart forgets it.
- Tests: controller tests for each answer, token from backend and from
  secret, screen count with a pinned and an unpinned shell, the broadcast
  reaching a connected shell.

## 5. Shell: interrupts next to overrides

Status: open

- The hook keeps at most one interrupt: the one shown, with its end
  computed on arrival (`performance.now()` based, so the screen clock does
  not matter).
- Incoming interrupt: shown if nothing is shown by an override or
  interrupt, or if its priority is equal or higher than what is; otherwise
  ignored. The same name again starts fresh (page loaded again, full
  duration).
- Override opening while an interrupt is shown: at each check, compare the
  active overrides with those of the last check (or of the old plan, when a
  new plan arrives). If one became active with priority equal or higher
  than the interrupt's, drop the interrupt and show what ADR 25 gives.
- Interrupt ends (time up, `done()`, `interrupt_end`): drop it and show
  what ADR 25 gives at that moment (highest active override, otherwise the
  rotation with the interrupted page).
- The check timer also fires at the end of the shown interrupt.
- Pinned screens ignore interrupt events.
- A reload or reconnect starts without an interrupt; no state survives.
- Tests: the decisions as pure functions in `schedule.js` with Node tests
  (incoming higher, equal, lower; override opening higher, equal, lower;
  replaced override coming back; same name again).

## 6. Catalog and status page

Status: open

- Catalog: section "Interrupts" next to overrides: name, page, priority,
  duration, description, the last trigger, the trigger URL (as text, with a
  `curl` example without token). Disabled ones in the disabled section.
- Status page: per configuration the number of connected screens and the
  last trigger of each interrupt with time, answer and screens; the warning
  from part 3.

## 7. Docs

Status: open

- pages.md: "Ending a page early" (`Deepsplay.done()`, minimum time, what
  happens per kind of page) and "Interrupts" (manifest, trigger, tokens,
  parameters, priority with overrides, a Python example for a backend).
- deployment.md: `interrupt_token`, HTTPS for triggers from outside.
- CHANGELOG entries.

## Open questions

- Page metadata `ends = true` (ADR 24), so the catalog can show that a page
  ends itself. Not decided; easy to add later.
- Conditions that last (e.g. a maintenance mode until it is switched off)
  are not interrupts: they must reach screens that connect later. A
  separate feature if needed, not part of this unit.
- Should an interrupt be limited by a time window (`when`), e.g. a doorbell
  page only during opening hours? Not part of this unit; the triggering
  system can decide.
- A JSON body for triggers instead of the query, for larger data. Not
  needed while parameters are what the page declares.
