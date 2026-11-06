# Phase 1 progress

Phase 1 is built in vertical slices. Each slice is tested and merged on its own.
Scope and design are in [outline.md](../outline.md); decisions in
[adr/](../adr/).

Status values: `open`, `in progress`, `done`.

| # | Slice | Status |
| --- | --- | --- |
| 1 | Host config and fallback page | done |
| 2 | Revision store | done |
| 3 | `screen.toml` parsing and validation | done |
| 4 | Static file serving | done |
| 5 | LiveView shell with rotation | done |
| 6 | Poller and live updates | done |
| 7 | Status page | done |
| 8 | Upstream proxy and host secrets | open |
| 9 | Release, container and kiosk notes | open |

## 1. Host config and fallback page

Status: done (2026-11-06)

Goal: load the host configuration (default and named configurations) and serve
`/` and `/c/<name>`, showing the fallback page while there is no content.

Done:

- `Deepsplay.HostConfig` parses the TOML host configuration (`toml_elixir`),
  collecting all errors: required and unknown keys, names, durations, `subdir`,
  duplicate names, `default_config`, upstream references, allowed git transports
  (`https`, `ssh`; also `file` in test).
- `Deepsplay.HostConfig.Store` loads it at startup from `DEEPSPLAY_CONFIG`
  (defaults: `config/deepsplay.dev.toml` in dev,
  `test/support/fixtures/host.toml` in test). A missing or invalid file does not
  stop the app; the errors are logged and shown on every screen.
- `DeepsplayWeb.ShellLive` on `/` and `/c/:name` shows the fallback page:
  waiting for content, unknown configuration, or host configuration errors.
  Repository URLs are shown without credentials.
- `Layouts.screen`: full-screen kiosk layout, no navigation, no flash, hidden
  pointer.
- Helpers `Deepsplay.Duration` and `Deepsplay.RepoUrl`.

Notes:

- An unknown configuration returns HTTP 200 with the fallback page.
- `[upstream.*]` tables are only checked for their names; contents follow in
  slice 8.

## 2. Revision store

Status: done (2026-11-06)

Goal: fetch a repository at a ref (depth 1), export the commit with
`git archive`, and atomically publish it to `rev/<sha>/` in the cache; remember
the last good SHA in `refs/` so it is served after a restart (ADR 6).

Done:

- `Deepsplay.Git` runs the git CLI isolated from user and system config, without
  prompts or hooks, limited to the allowed transports, with a timeout (kills git
  when it expires). Output has credentials removed from URLs.
- `Deepsplay.RevisionStore` with one `Writer` process per repository (started on
  demand under a `DynamicSupervisor`, found via `Registry`):
  - `publish/3`: shallow fetch into `mirror.git`, export with `git archive`,
    reject symlinks, run a `:validate` callback, atomic rename to `rev/<sha>/`,
    write `refs/<ref>` and the publish `history`. Existing revisions are reused.
    Branches, tags, full SHAs and refs with slashes work.
  - `last_good/3` and `revision_dir/3` read the disk directly, no network.
  - `prune/3` keeps SHAs in use plus the `keep_revisions` most recent others;
    `prune_repositories/2` removes directories of unconfigured repositories.
  - `tmp/` is emptied when a writer starts and after every publish.
- `Deepsplay.RepoUrl.key/1` (cache directory name) and `redact_text/1`.
- `Deepsplay.GitFixture` builds local test repositories over `file://`.

Notes:

- A rejected revision (symlinks, validator) is reported with its SHA, so the
  poller can skip it until the branch moves (slice 6).
- Refs are restricted to `[A-Za-z0-9._/-]`, must not start with `-` and must
  not contain `..`.
- Not yet: credentials for private repositories (slice 8), calling `publish`
  and running the prune functions on a schedule (slice 6), the `screen.toml`
  validator (slice 3).

## 3. `screen.toml` parsing and validation

Status: done (2026-11-06)

Goal: parse and validate the manifest of a revision before it is published,
including `rotation` (`sequential` or `random`) and page `weight`s; reject
invalid revisions and keep the previous good one.

Done:

- `Deepsplay.Screen.load/2` reads the manifest (default `screen.toml`, or the
  configured `manifest`; max 64 KiB) and collects all errors: `pages/` must
  exist, `title`, `rotation` (default `sequential`), at least one `[[page]]`,
  page `path` (relative to `pages/`, no `..`, not hidden, a regular file),
  `duration`, `weight` (number > 0, default 1.0, integers accepted), `uses`
  (only upstreams the configuration allows), unknown keys. A `[backend]` table
  is ignored with a warning (`warnings` field, for the status page).
- `Deepsplay.Screen.validator/1` plugs into `RevisionStore.publish/3`; it reads
  the configured manifest below the `subdir` and rejects a missing `subdir`.
- `Deepsplay.Screen.root/2` and `pages_dir/1` give a configuration's root and
  its `pages/` directory in a revision.
- Host configuration: optional `manifest` per configuration (relative path,
  not inside `pages/`), so several manifests in one repository can share pages
  (ADR 5).
- `Deepsplay.TomlSchema`: field reading and casting shared by the host
  configuration and `screen.toml`; `Deepsplay.HostConfig` now uses it.

Notes:

- `duration` is required for every page, also when only pinned pages are used.
- The same path may appear more than once in `[[page]]`.

## 4. Static file serving

Status: done (2026-11-06)

Goal: serve `/c/<name>/r/<sha>/<path>` from the revision directory with path and
symlink checks and long cache lifetimes (ADR 10).

Done:

- `DeepsplayWeb.RevisionController` on `GET /c/:name/r/:sha/*path`, outside the
  browser pipeline (no session, no CSRF). Files are served with
  `Cache-Control: public, max-age=31536000, immutable`,
  `X-Content-Type-Options: nosniff` and the type from the extension.
- `Deepsplay.RevisionFile.resolve/2`: only regular files below the root; no
  `..`, hidden (`.`-prefixed), empty or encoded-slash segments; every component checked with
  `lstat`, so symlinks are never followed. `sha?/1` accepts full SHA-1 and
  SHA-256 hashes.
- Unknown configuration, unknown or short SHA, missing file, directory or an
  unusable host configuration: `404` with `Cache-Control: no-store`.

Notes:

- Only `pages/` below the configuration's root (the repository, or its
  `subdir`) is served; paths are relative to it, like page paths and pinned
  pages. Manifests and everything else outside `pages/` answer `404`.
- Any revision still in the cache can be served, not only the current one, so
  screens on an older revision can finish loading it.
- Directories are not served; there is no `index.html` fallback.

## 5. LiveView shell with rotation

Status: done (2026-11-06)

Goal: the shell receives the plan and a JavaScript hook rotates the pages in
iframes, sequential or weighted random without repeats (ADR 9); `?page=`
pins a single file (ADR 11). First real milestone: a screen rotates pages from
a git repository.

Done:

- `DeepsplayWeb.ShellLive` builds the plan from the configuration's current
  revision and sends it to a colocated hook (`.Rotation`): two iframes; the
  next page loads in the hidden one only when it is due (no preloading, so
  animations start when shown), the old page stays visible until it has loaded
  (10 s timeout), they crossfade, and the old frame is cleared afterwards. Sequential, or weighted random without repeating the current page;
  a single or pinned page stays without a timer.
- New revisions arrive over PubSub; the plan is pushed as an event and the
  hook applies it at the next page change (pinned: at once). The fallback page
  switches to content by itself when the first revision arrives.
- `?page=<path>` pins any deliverable file in `pages/`; a missing, hidden or
  outside path shows a "Page not found" fallback. A current revision that does
  not fit the configuration (e.g. the manifest changed) shows "Revision
  unusable" with the errors.
- `DeepsplayWeb.ScreenPlan` builds plans and page URLs.
- Page paths in manifests, and `?page=`, may carry a query string that is
  passed on to the page (`a.html?duration=5s`); only the file part is checked,
  and the query must use URL characters only.
- `Deepsplay.Revisions`: `refresh/2` (publish with the configuration's
  validator, announce over PubSub), `current/2` (last good revision with its
  manifest, from the cache), `subscribe/1`, and `refresh_all/0`, which fetches
  every configuration once at startup (`:fetch_on_start`, off in test).
- `RevisionStore`: validation also runs when a revision is already cached, and
  `:remember_as` keeps a last good SHA per configuration, so configurations on
  the same repository and ref with different manifests do not affect each
  other.

Notes:

- Until slice 6, revisions are fetched only at startup; a restart picks up new
  commits.
- The hook logic was checked with a node simulation (order, no repeats,
  weighted shares, no loading before a page is due, no content change during
  the crossfade, clearing after the fade, plan switching, pinning, load
  timeout). It is not part of
  the test suite, as the project has no JavaScript test setup.

## 6. Poller and live updates

Status: done (2026-11-06)

Goal: one poller per repository and ref, publishing new revisions over PubSub
to running screens (ADR 7).

Done:

- `Deepsplay.RemoteRef.resolve/3`: one `git ls-remote` for
  `refs/heads/<ref>`, `refs/tags/<ref>` and the peeled tag; tells branches
  from tags; a full SHA needs no network.
- `Deepsplay.Poller`, one per repository and ref, started by
  `Deepsplay.Pollers` from the host configuration and shared by all
  configurations using them. First check right after start, then every
  `poll_interval` with ±20 % jitter. A new SHA refreshes every configuration
  (fetch, validate, publish, announce) and prunes old revisions; a SHA is acted
  on once, so a rejected one waits until the branch moves. Tags and SHAs are
  resolved once. Errors double the delay up to 5 minutes.
- `Deepsplay.Status`: last check, last error and next check per configuration
  (ETS), announced on the configuration's PubSub topic. The "Waiting for
  content" fallback page shows the last error and the next attempt.
- `Deepsplay.Janitor` removes cache directories of unconfigured repositories at
  start and once a day.
- The startup fetch of slice 5 is replaced by the pollers; `:start_pollers`
  (off in test) controls pollers and janitor.

Notes:

- Polling uses `git ls-remote` for every host (decided when starting this
  slice; ADR 7 updated). No GitHub API, no HTTP client dependency.
- A failed fetch counts as an error for the backoff and is retried at the next
  check; a rejected revision is not.
- The host configuration is still read only at startup: new or changed
  configurations need a restart.

## 7. Status page

Status: done (2026-11-06)

Goal: `/status` with Phoenix Presence: configurations with revision and last
poll, connected screens, recent errors.

Done:

- `DeepsplayWeb.StatusLive` at `/status`, updating live: configurations
  (source, revision or live token, manifest title, page count and rotation,
  last and next check, last error, manifest warnings such as an ignored
  `[backend]`), connected screens, and recent errors; an unusable host
  configuration is shown as well. Uses the app layout, whose generated
  Phoenix header was replaced by a plain deepsplay header.
- `DeepsplayWeb.Presence`: every connected shell is tracked with its
  configuration, state, revision, current page (the hook reports each page it
  shows), connection time, IP address and user agent. `?screen=<label>` names
  a kiosk on the status page.
- `Deepsplay.Status` keeps a log of the 50 most recent errors (a repeated
  error is logged once) and announces all changes on a common topic.

Notes:

- No login and no alerts, as planned; the page is meant for the internal
  network (open decision in the outline).
- Only connected screens are listed; a screen that disconnects disappears.
- Proxy failures will appear in the error log with slice 8.

## 8. Upstream proxy and host secrets

Status: open

Goal: `/c/<name>/api/<upstream>/<path>` with host-side secrets and a response
cache (ADR 8).

## 9. Release, container and kiosk notes

Status: open

Goal: `mix release`, container image with `git` and `openssh-client`, and notes
for setting up kiosk screens.

## Additions beyond the slices

### Local directories in development (ADR 12)

Status: done (2026-11-06)

- Host configuration: `path = "/abs/dir"` instead of `repo` and `ref`, only
  where `:allow_local_paths` is on (dev and test).
- `Deepsplay.LocalWatcher` (one per local configuration, started by
  `Deepsplay.Pollers`): watches the manifest and `pages/` with `file_system`
  (inotify), debounces 200 ms, keeps a version token in a `Registry` and
  announces each new one like a revision; manifest errors go to the status.
- `Revisions.current/2` reads local configurations live; the revision
  controller serves them from the directory with `Cache-Control: no-store`.
- Plans carry `apply`: `"now"` for local configurations, so the hook reloads
  the current page in place; `"next"` otherwise.
- Fallback pages show the directory instead of repository and ref.
