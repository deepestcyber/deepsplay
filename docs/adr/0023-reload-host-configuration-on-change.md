# 23. Reload the host configuration on change

Date: 2026-11-07

## Status

Accepted

## Context

The host configuration and the secrets file (ADR 5, ADR 8) are read once at
start. Adding a configuration, an upstream or a secret needs a restart, which
briefly disconnects every screen. Most of deepsplay reads the current host
configuration on every use; the pollers and local watchers, the upstream
cache, the shared state store and the cache cleanup take it once at start.

## Decision

A running server picks up a changed host configuration and secrets file on
its own.

- **Detecting changes**: both files are checked every 5 seconds for a
  changed content hash. Polling instead of file system events works in
  containers, with bind mounts and with files replaced by renaming (editors,
  Kubernetes config maps), and needs no `inotify-tools`. `SIGHUP` triggers a
  check at once.
- **Invalid changes are not applied**: the server keeps the last good
  version, logs the errors, and the status page shows them until a valid
  version arrives. A start with an invalid file behaves as before (fallback
  page with the errors).
- **Applying a valid change**:
  - the new version replaces the old one in the store;
  - pollers and local watchers are reconciled: new repositories and refs get
    one, unused ones stop, unchanged ones keep running with their schedule;
  - configurations whose content settings changed (repository, ref,
    `subdir`, `manifest`, upstreams, upstream rules) are fetched and
    validated again, as their last good revision may not suit the new
    settings;
  - screens of changed configurations reload; screens of a removed
    configuration show the fallback page and recover if it comes back;
  - a new `upstream_cache_size` applies at once (evicting if smaller);
    upstream settings apply from the next request;
  - the status page shows when the host configuration was loaded and a short
    summary of the last change.
- **Restart needed**: a changed `cache_dir` or `state_dir` is not applied to
  stores already in use; the status page says that a restart is needed.
  Environment variables (`DEEPSPLAY_CONFIG`, `DEEPSPLAY_SECRET_*`) are read
  at start only.
- Shared state and cache entries of a removed configuration are kept; the
  existing cleanups (ADR 6, ADR 20, ADR 21) handle them as before.

## Consequences

- Operators change configurations, upstreams and secrets without a restart
  and without screens going blank.
- A broken edit does no harm: it is rejected and shown, the last good
  version keeps running.
- Changes take effect within about 5 seconds; `SIGHUP` makes it immediate.
- Components that took settings once at start need a way to reconcile or to
  report that a restart is needed.
