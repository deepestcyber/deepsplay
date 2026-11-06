# 7. Poll branches instead of webhooks

Date: 2026-11-06

## Status

Accepted

## Context

Running screens should pick up a new revision when a branch moves. The server
usually sits on an internal network that git hosts cannot reach.

## Decision

deepsplay polls; there are no webhooks.

- One poller per repository and ref, however many configurations or screens use
  it.
- Interval `poll_interval` (default 30 s) with about 20 % random jitter.
- GitHub: conditional REST request (`If-None-Match` with the last ETag). Other
  hosts: `git ls-remote <url> <ref>`.
- Only branches are polled. Tags and full SHAs are resolved once at start.
- Errors back off exponentially up to 5 minutes and honour `Retry-After` and
  rate-limit headers. A SHA that failed validation is not retried until the
  branch moves again.
- A published revision is announced over Phoenix PubSub to every configuration
  using that repository and ref.

## Consequences

- Works behind firewalls and with any git host, no inbound access needed.
- Updates arrive with up to one interval of delay.
- Unchanged GitHub polls answer `304` and, per GitHub's documentation, do not
  count against the rate limit.
- Webhooks can be added later as an extra trigger for the same poller.
