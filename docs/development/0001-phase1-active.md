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
| 5 | LiveView shell with rotation | open |
| 6 | Poller and live updates | open |
| 7 | Status page | open |
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

Status: open

Goal: the shell receives the plan and a JavaScript hook rotates the pages in
iframes, sequential or weighted random without repeats (ADR 9); `?page=`
pins a single file (ADR 11). First real
milestone: a screen rotates pages from a git repository.

## 6. Poller and live updates

Status: open

Goal: one poller per repository and ref, publishing new revisions over PubSub
to running screens (ADR 7).

## 7. Status page

Status: open

Goal: `/status` with Phoenix Presence: configurations with revision and last
poll, connected screens, recent errors.

## 8. Upstream proxy and host secrets

Status: open

Goal: `/c/<name>/api/<upstream>/<path>` with host-side secrets and a response
cache (ADR 8).

## 9. Release, container and kiosk notes

Status: open

Goal: `mix release`, container image with `git` and `openssh-client`, and notes
for setting up kiosk screens.
