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
- Every host, GitHub included, is checked with
  `git ls-remote <url> refs/heads/<ref> refs/tags/<ref>`: one small request
  that returns only SHAs and transfers no objects. No host-specific API, so no
  HTTP client is needed.
- Only branches are polled. Tags and full SHAs are resolved once at start.
- Errors back off exponentially up to 5 minutes. A SHA that failed validation
  is not retried until the branch moves again.
- Each configuration's last check, last error and next check are kept in
  memory for the fallback and status pages.
- A published revision is announced over Phoenix PubSub to every configuration
  using that repository and ref.

## Consequences

- Works behind firewalls and with any git host, no inbound access needed.
- Updates arrive with up to one interval of delay.
- One code path for all hosts and both transports (`https`, `ssh`).
  `git ls-remote` is not subject to GitHub's REST rate limit; a host-specific
  API can still be added later if polling ever becomes a problem.
- Webhooks can be added later as an extra trigger for the same poller.
