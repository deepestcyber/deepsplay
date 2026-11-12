# Changelog

All notable changes are listed here. Versions follow `version` in `mix.exs`;
releases are tagged `vX.Y.Z` (see [docs/deployment.md](docs/deployment.md)).

## Unreleased

## 0.5.1 – 2026-11-12

deepsplay behind a reverse proxy with HTTPS. No changes are needed for
existing setups; `DEEPSPLAY_ORIGINS` keeps working.

- Behind a reverse proxy with HTTPS, screens and the status page failed the
  WebSocket origin check unless `DEEPSPLAY_ORIGINS` listed the names.
  `DEEPSPLAY_TRUSTED_PROXIES` names the proxies (IP addresses or CIDR
  ranges) whose `X-Forwarded-Proto` and `X-Forwarded-For` deepsplay trusts,
  so the status page also shows the screens' own addresses; other clients'
  headers are ignored, host and port never come from headers (ADR 34,
  [deployment.md](docs/deployment.md#behind-a-reverse-proxy)).

## 0.5.0 – 2026-11-12

Pages that end themselves, interrupts over HTTP and MQTT. No changes are
needed for existing setups; interrupts and MQTT stay off until a manifest
declares `[[interrupt]]` pages and the host configuration gives a way to
trigger them. Screens load the new shell on their own when they reconnect
after the update.

- Pages can end their display time with `Deepsplay.done()`; `duration`
  becomes an upper limit. On an override, `done()` ends it on that screen
  until its window closes. Pages are shown at least 2 seconds (ADR 31,
  [pages.md](docs/pages.md#ending-a-page-early)).
- Interrupts: a manifest declares `[[interrupt]]` pages that backends or
  other systems put on all screens of a configuration at once, with
  `POST /c/<config>/interrupts/<name>` and a bearer token (a backend's
  `DEEPSPLAY_TOKEN`, or the secret named by the new `interrupt_token` in the
  host configuration). Their priority decides against overrides and other
  interrupts; the catalog and the status page show the last trigger
  (ADR 32, [pages.md](docs/pages.md#interrupts)).
- Interrupts over MQTT: with an `[mqtt]` section in the host configuration
  (TLS, user name, password from the secrets), deepsplay connects to a
  broker and starts interrupts from messages on each configuration's
  `mqtt_topic`; the topic's last level names the interrupt and a JSON
  payload carries the page parameters. Retained messages are ignored. The
  status page shows the connection, the catalog each interrupt's topic
  (ADR 33, [deployment.md](docs/deployment.md)). Without `[mqtt]` nothing
  changes. New dependency: `emqtt` (built without QUIC).
- The status page shows how many screens each configuration has connected.
- `/lib/v1/deepsplay.js` is cached for an hour instead of a day and has an
  `ETag`, so a new build reaches screens within about an hour. Screens that
  cannot reach the server keep using their copy for 30 days instead of 8
  (ADR 14).

## 0.4.0 – 2026-11-09

Shorter manifests, entries that can be switched off and second-precise time
windows. No changes are needed for existing setups; screens load the new
shell on their own when they reconnect after the update.

- Manifest page entries can name their pages with `glob` (and `exclude`)
  instead of `path`; each page found becomes an entry of its own (ADR 28).
- Page entries and overrides can be switched off with `enabled = false`;
  the catalog lists them as disabled (ADR 29).
- Time windows may have seconds (`"11:59:30"`, `"2027-03-04 10:00:15"`);
  screens then check overrides every second (ADR 30).
- Screens load the page again when they reconnect after an update of
  deepsplay, so they always run the current shell.

## 0.3.1 – 2026-11-08

Fixes the image build of 0.3.0, which has no published image. No changes are
needed for existing setups.

- Image build: downloading Tailwind from
  `github.com/tailwindlabs/tailwindcss/releases/download/...` failed with
  `504 Gateway Time-out` while the GitHub API kept working. If `mix
  assets.setup` fails, the Dockerfile now fetches the same executable through
  the API (`docker/fetch_tailwind.exs`); CI passes its `GITHUB_TOKEN` as the
  build secret `github_token` for the API's rate limit. See "Releasing" in
  [docs/deployment.md](docs/deployment.md).

## 0.3.0 – 2026-11-08

A clearer catalog and longer page documentation. No changes are needed for
existing setups.

- Catalog page of a configuration: an overview of all pages (name, file,
  first line of the description, preview, playground and pin links) at the
  top; the parameter list of each page is collapsed.
- Pages and helpers can have `details`, a longer plain text shown collapsed
  in the catalog and returned by `Deepsplay.page()` (ADR 27).

## 0.2.0 – 2026-11-08

Phases 2 and 3 and two smaller units (see [docs/development](docs/development/)):
documented pages with parameters and a page catalog, upstreams with a shared
cache, shared state, backends, time windows, and live reloading of the host
configuration.

Changes for existing setups:

- Sizes: `MB` and `GB` now count in powers of 1000; existing values shrink by
  about 5% (`MB`) or 7% (`GB`), and the default `upstream_cache_size` is now
  200,000,000 bytes. Use `MiB`/`GiB` for the old meaning.
- The host configuration and the secrets file are reloaded while running;
  an invalid edit is rejected and shown on the status page instead of taking
  effect at the next restart.
- The container image runs under `tini` (new entrypoint) and includes `uv`.
- The upstream cache and shared state are kept below `cache_dir`
  (`.upstream/`, `.state/`); keep `cache_dir` on a persistent volume, or set
  `state_dir` to keep shared state elsewhere.

- The status page shows the app version.
- Manifests can set a default `duration` for all pages; a page's `duration` is
  optional and falls back to the manifest's, or to 15 seconds.
- Page helper `deepsplay.js` at `/lib/v1/deepsplay.js`: pages define their
  parameters in a TOML block and read them typed, with defaults and limits;
  `Deepsplay.api()` builds upstream URLs (ADR 14).
- Shared helpers register their parameters with `Deepsplay.helper()`
  (ADR 15).
- Default parameters per configuration (`params = {…}`) and per manifest
  (`[params]`), and the display time for parameters with `from = "duration"`,
  are added to the URLs of pages that declare them (ADR 16).
- Page catalog at `/catalog`: per configuration the rotation, all pages with
  their documentation and parameters, helpers and warnings; preview at
  different screen sizes and a playground for parameters (ADR 17).
- Guide for building content repositories (`docs/pages.md`); the development
  configuration shows the template repository (ADR 18).
- The upstream proxy coalesces requests: concurrent requests for the same
  cacheable answer share one upstream call. Cacheable answers carry
  `X-Deepsplay-Cache` (`hit`, `miss` or `stale`) and `Age` (ADR 20).
- Upstream option `stale_ttl`: an expired answer is kept that long and served
  while the upstream fails (timeout, connection error, `429` or `5xx`)
  (ADR 20).
- The upstream cache is limited by `upstream_cache_size` (default 200 MB),
  dropping the least recently used answers, and kept in
  `cache_dir/.upstream/` across restarts (ADR 20).
- Upstream option `refresh = true`: answers requested within the last three
  times `cache_ttl` are fetched again shortly before they expire, so screens
  get cache hits and the upstream one call per `cache_ttl` (ADR 20).
- Manifests can declare upstreams for open APIs (`[upstream.<name>]` with
  `url` and `cache_ttl`): `https` and `GET` only, no secrets, only hosts with
  public addresses. The host allows them by default and can switch them off
  or limit them to host patterns (`repo_upstreams`, `repo_upstream_hosts`,
  per server or configuration); the catalog shows them (ADR 19).
- The status page lists upstreams with where they are defined, their cache
  entries and size, hits, misses, stale answers, last call and last error,
  and the total cache size (ADR 20).
- Shared state for pages at `/c/<config>/state/<key>`: JSON values with
  versions, conditional writes (`If-Match`, `If-None-Match: *`), atomic
  increments and listing by prefix, shared by the configurations of one
  repository and ref, kept in `state_dir` (ADR 21). Pages use it with
  `Deepsplay.state` (`get`, `set`, `delete`, `increment`, `list`, `update`)
  in `deepsplay.js`. The status page lists namespaces; the catalog shows a
  configuration's keys with shortened values.
- Upstream options `accepted_types` (answers of other content types, e.g. an
  XML error sent with `200`, count as failures: not cached, stale answer
  served) and `cache_size` (an upstream's share of the cache), for host and
  manifest upstreams (ADR 22).
- Sizes take SI units (`kB`, `MB`, `GB`, powers of 1000) and binary units
  (`KiB`, `MiB`, `GiB`, powers of 1024), and decimals. `MB` and `GB` used to
  count in powers of 1024: existing values shrink by about 5% (`MB`) or 7%
  (`GB`); the default `upstream_cache_size` is now 200,000,000 bytes. Pages
  show sizes in SI units.
- Optional `description` for configurations, host and manifest upstreams,
  manifests and page entries, shown on the status page and in the catalog.
- Page metadata: optional `author`, `credits` and `license` in the parameter
  block of pages and helpers, shown in the catalog; `Deepsplay.page()` gives
  pages and themes their metadata (ADR 24).
- The host configuration and the secrets file are reloaded when they change
  (checked every 5 seconds, at once on `SIGHUP`): pollers and local watchers
  follow, screens of changed configurations reload, an invalid change is
  rejected and shown on the status page while the last good version keeps
  running (ADR 23).
- Time windows for pages (`when` with `start`/`end`, `dates`, `days`,
  `from`/`until`), `when_empty` for times without an active page, and
  `[[override]]` pages that interrupt the rotation during their windows,
  with priorities; the catalog shows windows and overrides (ADR 25).
- Backends: a content repository can bring a Python backend (`[backend]` in
  the manifest), installed with `uv`, supervised by deepsplay and reached by
  its pages at `/c/<config>/backend/`. Only for configurations with
  `backend = true`; a revision is shown once its backend is ready. Secrets
  per configuration (`backend_secrets`), memory limit (`backend_memory`),
  restarts on changes of local directories; the status page shows state and
  recent output. The container image includes `uv` and `tini` (ADR 26).

## 0.1.0 – 2026-11-07

First version (phase 1, see [docs/development](docs/development/)).

- Screens show pages from git repositories, rotating them sequentially or
  weighted at random; a single page can be pinned with `?page=`.
- Host configuration in TOML with named configurations; manifests in the
  content repositories; only `pages/` is delivered.
- Revision cache keyed by commit SHA, kept across restarts; new commits are
  picked up by polling and reach running screens live.
- Status page with configurations, connected screens and recent errors.
- Upstream proxy with host-side secrets and a response cache; credentials for
  private repositories.
- Local directories served live in development.
- Container image for amd64 and arm64, built by GitHub Actions.
