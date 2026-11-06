# 12. Serve local directories in development

Date: 2026-11-06

## Status

Accepted

## Context

Building pages against a local git repository (ADR 6) shows changes only after
a commit. Working on pages, especially in big repositories, needs every save to
show at once, without commits and without copying the repository.

## Decision

In development, a configuration can serve a local directory directly:
`path = "/abs/dir"` instead of `repo` and `ref`.

- Allowed only where the `:allow_local_paths` setting is on (dev and test),
  never in prod. `subdir`, `manifest` and `upstreams` work as for repositories.
- Files are served straight from `<dir>/pages/`, with the same path checks
  (no `..`, no hidden files, no symlinks), and with `Cache-Control: no-store`.
  No git, no cache directory, no copies.
- A watcher per configuration keeps a random version token that takes the
  place of the commit SHA in page URLs, and replaces it on every change to the
  manifest or to non-hidden files in `pages/`. Changes are detected with OS
  file notifications (`file_system`, a dev and test dependency), watching
  `pages/` recursively and the manifest's directory on its own; bursts are
  handled as one after 200 ms.
- A new token is announced like a new revision. Plans of local configurations
  apply at once: the screen reloads the current page in place, also when
  rotating.
- The manifest is read live. If it is invalid, the screen shows the errors;
  there is no "last good" version.

## Consequences

- Every save shows on screen within a fraction of a second, also in big
  repositories, since nothing is copied and only the relevant directories are
  watched.
- The URL scheme stays the same; the token changes the URLs of the page and of
  everything it loads relatively, so nothing stale is cached.
- A file caught mid-write can be served half-saved; the next save fixes it.
- Development serves differently from production in this mode. A local git
  repository (ADR 6) remains the way to test the production path.
