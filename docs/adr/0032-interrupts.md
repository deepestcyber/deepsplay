# 32. Interrupts

Date: 2026-11-11

## Status

Accepted

Amends [9](0009-rotation-in-the-browser.md),
[10](0010-url-scheme.md), [16](0016-default-parameters-per-configuration.md),
[25](0025-time-windows-and-overrides.md) and [26](0026-sidecars.md).

## Context

Overrides (ADR 25) interrupt the rotation at times known in advance. Some
events are not: someone rings the doorbell, a build breaks, a goal is
scored. A backend (ADR 26) or another system on the network learns of them
and needs every screen of a configuration to show a page at once.

Screens hold a LiveView connection to the server, but so far the server
only sends them plans; what is on screen is decided in the browser.

## Decision

A manifest declares **interrupts**: pages that are shown on all screens of
a configuration when the interrupt is triggered over HTTP.

The manifest:

```toml
[[interrupt]]
name     = "doorbell"
path     = "doorbell.html"
duration = "30s"
priority = 20
```

- `name` (required): `^[a-z0-9][a-z0-9_-]*$`, at most 64 characters, unique
  in the manifest.
- `path` (required): a page in `pages/`, with an optional query, as for
  pages.
- `duration` (required): how long the interrupt lasts at most. The page can
  end it earlier on its screen with `Deepsplay.done()` (ADR 31).
- `priority` (integer, default 0), `description`, `uses` and `enabled`
  (ADR 29) as for overrides.
- Invalid entries reject the revision, like other manifest errors.

Triggering:

- `POST /c/<config>/interrupts/<name>` starts the interrupt on the screens
  connected at that moment; `DELETE` on the same path ends it on the screens
  showing it.
- The request needs `Authorization: Bearer <token>`:
  - A backend gets a token in `DEEPSPLAY_TOKEN`. deepsplay creates it when
    it starts the process and keeps it only in memory; it changes with
    every start.
  - Other systems use a token from the secrets (ADR 8): `interrupt_token =
    "<secret name>"` in the configuration's `[[config]]` in the host
    configuration names it.
  - Pages never get a token: anything in a page can be read on the network.
  - Tokens are compared in constant time. They travel in plain text over
    plain HTTP, like everything else on port 4000; callers from outside the
    internal network go through a reverse proxy with HTTPS.
- The query of the request is passed to the page as parameters, only
  parameters the page declares (itself or through a helper in `uses`,
  ADR 14), checked against their definitions. They take precedence over the
  query in the manifest path and all other levels of ADR 16. A parameter
  with `from = "duration"` gets the interrupt's duration.
- Answers: `202` with the number of screens the event was sent to
  (connected, not pinned) and the duration; `401` without a valid
  token; `404` for an unknown or disabled interrupt, or a configuration
  without a revision; `422` for parameters the page does not declare or
  values that do not fit their definition; `429` when the same interrupt is
  triggered again within 2 seconds. The query is limited to 2 KB.
- Triggering an interrupt that is shown starts it fresh: new parameters,
  page loaded again, full duration.

Interrupts are events:

- deepsplay does not keep interrupts. A trigger is checked, sent to the
  screens of the configuration that are connected at that moment, and
  forgotten; only the last trigger of each interrupt is kept, for the
  status page and the rate limit.
- A screen shows an interrupt from the moment the event arrives, for its
  duration, counted by the screen; the screen's clock does not matter.
- A screen that is not connected at that moment, or reconnects or reloads
  later, never sees it. Once an interrupt is off a screen, it is gone there:
  it ended, the page called `Deepsplay.done()` (ADR 31), the screen
  reloaded, or something replaced it.
- A new revision does not end an interrupt that is shown; it finishes.

On the screen:

- An incoming interrupt replaces what is shown (an override or another
  interrupt) if its `priority` is equal or higher; otherwise it is ignored.
- An override whose window opens while an interrupt is shown replaces the
  interrupt if its `priority` is equal or higher. The interrupt is dropped.
  An override becomes active also when a new revision brings it.
- An override replaced by an interrupt is not dropped: when the interrupt
  ends and the override's window is still open, it comes back.
- Overrides among themselves follow ADR 25 unchanged: the highest priority
  wins, with equal priority the first in the list.
- When an interrupt ends, the screen shows what ADR 25 gives at that
  moment: the active override with the highest priority, or the rotation.
- Interrupts are shown also when no rotation page is active (before
  `when_empty`). Pinned pages (`?page=`) ignore interrupts.

Visibility: the catalog lists the interrupts with page, priority and
duration, the trigger URL and the last trigger. The status page shows the
last trigger of each interrupt with its time, answer and number of screens,
and how many screens of the configuration are connected.

## Consequences

- Backends and other systems can put a page on every screen of a
  configuration at once, without editing the manifest.
- What is on screen is no longer decided by the browser alone: the server
  pushes events, and screens without connection miss them (ADR 9 kept
  screens fully working offline). A screen that is reconnecting or reloading
  (e.g. after an update) misses interrupts sent in that moment.
- deepsplay gets its first authenticated route, and a host configuration
  can hold a token per configuration.
- Screens can show different things after an interrupt: one that reloaded
  shows the rotation or an override while the others still show the
  interrupt, until it ends.
- The caller learns how many screens got the event, not whether they
  showed it (a screen ignores an interrupt of lower priority than what it
  shows).
- Interrupts suit events that matter now. Conditions that last (e.g. a
  maintenance mode until it is switched off) are a different feature: they
  must reach screens that connect later, and are not covered here.
- Interrupts reach all screens of a configuration. Reaching single screens
  would need screens with names, which they do not have.
