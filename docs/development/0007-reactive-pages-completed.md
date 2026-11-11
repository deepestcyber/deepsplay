# Reactive pages

Status: done (2026-11-11)

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
| 2 | Manifest: `[[interrupt]]` | done |
| 3 | Tokens: host configuration and backends | done |
| 4 | Trigger route and broadcast | done |
| 5 | Shell: interrupts next to overrides | done |
| 6 | Catalog and status page | done |
| 7 | Docs | done |

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

Also: `/lib/v1/deepsplay.js` is now cached an hour with an `ETag` and up to
30 days stale (ADR 14 amended), so `done()` reaches screens within about an
hour after an update. pages.md "Ending a page early" and the CHANGELOG entry
are written; part 7 adds the interrupts.

## 2. Manifest: `[[interrupt]]`

Status: done

- `Deepsplay.Screen`: `@interrupt_fields` with `name` (required, upstream
  name rule), `path` (required, with query, file must exist), `duration`
  (required), `priority` (default 0), `description`, `uses`, `enabled`.
- New struct `Deepsplay.Screen.Interrupt`. The screen gets `interrupts`;
  disabled ones go to `disabled` like pages and overrides (ADR 29).
- Duplicate names are an error. `page = false` files get the usual warning.
- Tests in `screen_test.exs`: valid entries, missing fields, duplicates,
  bad names, disabled.

Built:

- `Deepsplay.Screen.Interrupt`; `Screen` reads `[[interrupt]]` into
  `interrupts`, disabled ones into `disabled`. Duplicate names are an error
  also when one of them is disabled, since a trigger names one.
- The catalog lists disabled interrupts as `(interrupt)` with their name;
  the rest of the catalog comes with part 6.
- Moved to part 4: the warning for a `page = false` file. It comes from
  `PageParams` when the page URL is built, as for pages.

## 3. Tokens: host configuration and backends

Status: done

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

Built:

- `interrupt_token` in `[[config]]`, an error when the secret is not
  defined. `Deepsplay.InterruptTokens` reads the secret at each check, so a
  changed secret or host configuration counts at once.
- `Deepsplay.InterruptTokens`: a `Registry` with duplicate keys per
  configuration. `Deepsplay.Backend` creates a token at each launch of the
  process (also after a crash), registers it and passes it as
  `DEEPSPLAY_TOKEN`; it is dropped when the process exits, and with the
  `Backend` process. During a backend swap both tokens are valid until the
  old one stops. `valid?/2` compares with every candidate in constant time.
- The warning is a manifest warning (`Screen` knows the configuration and
  whether it runs a backend), so it shows where the other manifest
  warnings show.
- Tests: `interrupt_tokens_test.exs`, `host_config_test.exs`,
  `backend_test.exs` (token in the environment, new after a crash, old one
  invalid), `screen_test.exs` (warning).

## 4. Trigger route and broadcast

Status: done

- Route `POST` and `DELETE /c/:name/interrupts/:interrupt`, a controller
  outside the browser pipeline (no CSRF, no session), with a plug for the
  bearer token.
- `page = false` warning for interrupt pages, from `PageParams` (moved
  from part 2).
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

Built:

- `DeepsplayWeb.InterruptController` on `POST`/`DELETE
  /c/:name/interrupts/:interrupt`, outside the browser pipeline. The token
  is checked first (`401`, with `WWW-Authenticate: Bearer`), then the
  interrupt (`404`). Answers are JSON and `no-store`.
- `DeepsplayWeb.Interrupts`: finds the interrupt in the current revision,
  checks the query (2 KB, no name twice, `PageParams.check/3` against the
  page's definitions), builds the URL (trigger parameters, the rest of the
  manifest query, then the ADR 16 levels with the interrupt's duration),
  broadcasts on `"interrupts:<name>"` and answers with the screen count. An
  ETS table keeps the last answer per interrupt (`last/1`, for part 6) and
  the last start for the rate limit; only accepted starts count for it.
- Out-of-range numbers are clamped, not rejected, as the page helper does;
  only values that cannot be read as the type give `422`.
- Screen count from `DeepsplayWeb.Presence` (already tracking shells):
  connected, `state: :playing`, not pinned (new `pinned` in the meta). No
  separate registry.
- `ShellLive` subscribes to the topic and pushes `interrupt` (name, URL,
  priority, duration) or `interrupt_end` (name), not when pinned or without
  a revision. The hook ignores them until part 5.
- The `page = false` warning now reads "in the rotation or an interrupt";
  `Revisions` adds the warnings of interrupt pages to the parameter
  warnings.

## 5. Shell: interrupts next to overrides

Status: done

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

Built:

- `schedule.js`: `acceptsInterrupt/2`, `activeOverrideKeys/3`,
  `overrideOpened/5`, with Node checks.
- Hook: mode `"interrupt"` next to `"override"`; `startInterrupt`,
  `endInterrupt` (time, `done()`, `interrupt_end`), `resume` shared with the
  end of an override. `activeKeys` holds the overrides active at the last
  check; an override not among them that is active now with equal or
  higher priority drops the interrupt. Starting an interrupt refreshes
  `activeKeys`, so overrides already active do not count.
- A plan arriving during an interrupt, or waiting when one starts, applies
  at once (nothing of the rotation is visible), so overrides it brings
  count; the rotation then starts over instead of resuming. Without this, a
  new override waited for the next page change, up to the page's duration.

Checked in headless Chromium against a production build (2026-11-11),
pages of 60 s, interrupts of 8 s:

- interrupt during the rotation: shown, then the interrupted page again;
- higher replaces lower; lower during higher ignored; `done()` after 3 s
  ends it; `DELETE` ends it;
- override (priority 5) opening during an interrupt of 0: replaces it;
  interrupt of 10 during the override: replaces it, the override comes
  back; interrupt of 0 during the override: ignored; interrupt of 5:
  replaces it, the override comes back, then the rotation at the window's
  end;
- override opening during an interrupt of 10: ignored, shown when the
  interrupt ends;
- the same interrupt again after 4 s: loaded again, ends 8 s after the
  second trigger.

## 6. Catalog and status page

Status: done

- Catalog: section "Interrupts" next to overrides: name, page, priority,
  duration, description, the last trigger, the trigger URL (as text, with a
  `curl` example without token). Disabled ones in the disabled section.
- Status page: per configuration the number of connected screens and the
  last trigger of each interrupt with time, answer and screens; the warning
  from part 3.

Built:

- Catalog: section "Interrupts" (`#interrupt-<name>`) with description,
  page, duration, priority, a `curl` example with `$TOKEN` and the full URL
  (from the endpoint's URL), and the last trigger. Disabled ones were
  already listed (part 2).
- Status page: the number of connected screens under each configuration's
  name, and a table "Interrupts" with each interrupt of the current
  revisions, its priority and last trigger. The warning shows with the
  other manifest warnings (part 3).
- Both pages update when an interrupt is triggered: `Interrupts` calls the
  new `Status.notify/1`.
- `Interrupts.describe/1` writes a trigger as e.g. "POST 2026-11-11
  17:00:00 UTC, 202 to 2 screens".
- Tests: `interrupt_pages_test.exs`.

## 7. Docs

Status: done

- pages.md: "Ending a page early" (done with part 1) and "Interrupts" (manifest, trigger, tokens,
  parameters, priority with overrides, a Python example for a backend).
- deployment.md: `interrupt_token`, HTTPS for triggers from outside.
- CHANGELOG entries.

Built: pages.md "Interrupts" (and `DEEPSPLAY_TOKEN` under Backends),
deployment.md and `deploy/host.example.toml` with `interrupt_token`, the
CHANGELOG entries.

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
