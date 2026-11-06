# 2. Elixir and Phoenix as platform

Date: 2026-11-06

## Status

Accepted

## Context

deepsplay serves HTML pages from git revisions to kiosk screens, pushes new
revisions to running screens, polls git hosts in the background and proxies
upstream calls. It is built and maintained by a very small team.

## Decision

We build deepsplay in Elixir (`~> 1.20`) on Phoenix, served by Bandit, built
with Mix and deployed as an OTP release.

- LiveView is used where live state matters (screen shell, status page), not
  for everything.
- Background work (pollers, per-repository cache writers) runs as supervised
  OTP processes inside the same app; new revisions are announced over
  Phoenix PubSub.
- `mix precommit` (`compile --warnings-as-errors`, `deps.unlock --unused`,
  `format`, `test`) must pass before a change is done.
- Where Phoenix generators exist, we use them and own the generated code.

## Consequences

- One application covers web serving, live updates and background jobs, with
  no separate queue or JS frontend.
- Phoenix conventions decide layout and structure.
- The ecosystem is smaller than Node's or Python's; some things we write
  ourselves.
- Deployment needs an OTP release, usually in a container.
