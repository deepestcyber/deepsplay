# Phase 3: server services for pages

Phase 3 plans what deepsplay offers pages on the server side, so that pages
stay plain HTML in most cases: better caching of upstream data, shared state,
and, for genuinely custom logic, sidecars. It starts with planning; each part
ends with a decision (usually an ADR) before anything is built.

Background: [outline.md](../outline.md) and [adr/](../adr/), in particular
ADR 5 (manifests, nothing from a repository is evaluated as code), ADR 8
(secrets and upstream proxy), ADR 10 (URL scheme, `/c/<name>/backend/*`
reserved), ADR 12 (local directories in dev) and ADR 13 (container image).

Status values: `open`, `in progress`, `done`.

| # | Part | Status |
| --- | --- | --- |
| 1 | Upstream cache for expensive and rate-limited providers | done |
| 2 | Shared state for pages | in progress |
| 3 | Sidecars | open |

## 1. Upstream cache for expensive and rate-limited providers

Status: done (2026-11-07), decided in ADR 19 and ADR 20; built

Goal: data from expensive or rate-limited providers is fetched as rarely as
possible and stays available when the provider fails, for all screens at once.

Today: the upstream proxy caches successful `GET` answers in memory for an
upstream's `cache_ttl`, only for upstreams the host defines; caching arbitrary
URLs would make deepsplay an open proxy.

Decided in
[ADR 19](../adr/0019-upstreams-declared-in-content-repositories.md): manifests
can declare upstreams without secrets (`[upstream.<name>]` with `url` and
`cache_ttl`), so open APIs such as DWD rain radar get a shared cache without
touching the host configuration. Guards: `https` and `GET` only, target
addresses checked after DNS resolution at connect time (no loopback, private
or link-local addresses), no redirects, `cache_ttl` of at least one minute,
size limit for text and binary bodies. The host allows this by default, per
configuration or for listed host name patterns, and can switch it off.

Decided in [ADR 20](../adr/0020-upstream-cache.md), for host and manifest
upstreams:

- **Coalescing**: per cache key at most one upstream request in flight;
  concurrent requests wait for its result. Only successes are cached; waiting
  is bound by the upstream timeout; manifest upstreams share entries by
  target URL.
- **Stale answers**: `stale_ttl` (off by default); served when a fetch fails
  with a timeout, connection error, `429` or `5xx`. Headers
  `X-Deepsplay-Cache` and `Age`.
- **Scheduled refresh**: `refresh = true` refetches keys requested within the
  last three times `cache_ttl`, shortly before they expire.
- **Persistence and limits**: `upstream_cache_size` for memory and disk
  together, least recently used dropped first; every entry also in
  `cache_dir/.upstream/`, loaded again on start (wall-clock expiry).
- **Status page**: per upstream origin, entries, hits, misses, stale answers,
  last fetch and error; total size against the limit.

ADR 19 details: server settings `repo_upstreams` (default `true`) and
`repo_upstream_hosts` (patterns `dwd.de`, `*.dwd.de`), overridable per
configuration; resolved addresses all checked, connection to a checked
address with the host name for TLS and `Host`.

Planning is complete. Build steps, each tested on its own:

1. Coalescing, `X-Deepsplay-Cache` and `Age`: built (2026-11-07). Fetches run
   in tasks of `Deepsplay.UpstreamProxy.Tasks`, started by the cache process,
   which keeps the waiting requests per key; a task carries `$callers` of the
   request that started it.
2. Stale answers (`stale_ttl`): built (2026-11-07). `stale_ttl` needs
   `cache_ttl`. A stale value also replaces a crashed fetch or a request that
   waited longer than allowed.
3. Size limit with least-recently-used eviction, and persistence: built
   (2026-11-07). Sizes are measured as `:erlang.external_size/1` of the
   cached answer; recent use is ordered by a monotonic counter, not a clock.
   A single answer larger than the limit is not cached. Disk writes and
   deletes run in order in `Cache.Disk`, one file per entry named by a hash of
   its key; the cache syncs them on shutdown. Tests keep the shared cache in
   memory (`persist_upstream_cache`) and start their own caches for
   persistence.
4. Scheduled refresh (`refresh = true`): built (2026-11-07). `refresh` needs
   `cache_ttl`. The refresh runs a tenth of `cache_ttl` before expiry (at most
   5 seconds before), reusing the fetch of the request that cached the entry.
   A refresh keeps the time of the last request, so entries nobody asks for
   stop. Entries loaded from disk join the refresh on their first request. A
   failed refresh is not retried; the entry expires and the next request
   fetches (or gets the stale answer).
5. Manifest upstreams: parsing, host switch, address check, catalog (ADR 19):
   built (2026-11-07). Manifest upstreams use the `Upstream` struct with
   `origin: :manifest` (parsed in `Deepsplay.Screen.Upstreams`); invalid ones
   still count as declared for `uses`. The manifest of a revision is kept in
   memory (`Pages.memo`), as the proxy reads it with every request.
   `UpstreamProxy.Address` resolves all addresses (tests use
   `:proxy_resolver`) and refuses non-public ones; the request goes to the
   address with Mint's `hostname` option, checked against DWD: TLS
   verification works, a wrong name fails. A manifest upstream named like a
   host upstream the configuration allows is an error; one named like a host
   upstream the configuration does not allow is used.
6. Cache state on the status page: built (2026-11-07). Counters live in
   `UpstreamProxy.Stats` (since the start, in memory), grouped like cache
   entries: host upstreams by name, manifest upstreams by URL. The cache
   keeps the group per entry (also on disk) for entry counts and sizes. A
   `429` or `5xx` answer counts as the last error, as do transport errors.
   The status page lists host upstreams, then manifest upstreams with the
   configurations declaring them, and refreshes the counters every 5
   seconds.

## 2. Shared state for pages

Status: in progress (decided, not built)

Goal: pages can keep small state on the server, shared by all screens and
pages of their content, without a server component of their own.

Already clear:

- State per display needs no server: the browser's `localStorage` is shared by
  a screen's pages (they share one origin) and survives reloads as long as the
  kiosk browser keeps its profile. Phase 2 (repository conventions) recommends
  a key prefix per page.
- Borders cannot be enforced: pages run in the browser on one origin and can
  call any URL, including another configuration's state. Separation is a
  matter of organisation, as for the upstream proxy.

Decided in [ADR 21](../adr/0021-shared-state-for-pages.md):

- **Scope**: shared by all pages of a namespace. The server derives the
  namespace from the configuration: by default the content root
  (repository, ref and `subdir`, or a local path); `state = "<name>"` for a
  named one, `state = false` for none. Keys are free strings (`<page>/...`,
  `shared/...` by convention).
- **API** at `/c/<config>/state/` (added to ADR 10): `GET`, `PUT`, `DELETE`
  per key with JSON values and versions (`ETag`); `If-Match` and
  `If-None-Match: *` for conditional writes; `POST` with `{"increment": n}`
  for counters; listing by prefix. `Deepsplay.state` in `deepsplay.js`.
- **Live updates**: none; pages poll. Server-sent events can follow.
- **Limits**: 64 KB per value, 1000 keys and 5 MB per namespace.
- **Persistence**: server setting `state_dir` (default
  `<cache_dir>/.state/`), one JSON file per namespace, written within a
  second of a change.
- **Trust**: no login or token; state is neither secret nor protected.
  `shared_state = false` on the server, or `state = false` per
  configuration, switches it off.
- **Local directories**: same store, path as namespace.
- **Visibility**: namespaces on the status page; keys and shortened values in
  the catalog.

Build steps, each tested on its own:

1. Store and host settings: built (2026-11-07). `Deepsplay.State` keeps
   values as encoded JSON in a table (reads) and writes through its process
   (conditions, limits, increments). Versions come from a counter per
   namespace, so a deleted and recreated key never repeats one. Namespaces:
   `repo:<repo key>@<ref>/<subdir>`, `path:<dir>`, `name:<name>`. Files in
   `state_dir` are named by a hash of the namespace and hold it, with `seq`,
   `written_at` and the keys; they are written a second after the first
   change and on shutdown. Tests keep the shared store in memory
   (`persist_state`) and start their own stores for persistence.
2. HTTP API at `/c/<config>/state/`: built (2026-11-07). Bodies are read
   unparsed for any content type (the state routes skip `Plug.Parsers`, like
   the proxy), so the 64 KB limit applies before parsing. Errors answer JSON
   `{"error": ...}`; a non-number for an increment answers `409`, a malformed
   `If-Match` `400`. Answers carry `Cache-Control: no-store`.
3. `Deepsplay.state` in `deepsplay.js`, and the guide: built (2026-11-07).
   Functions return promises; `get` gives `undefined` for a missing key,
   `entry` gives value and version. `set` takes `{ ifVersion }` or
   `{ onlyNew: true }`; `update(key, fn)` retries up to 10 times on `412`.
   Errors carry `status`. Tested in Node against a stand-in server, and once
   end to end against a running deepsplay.
4. Namespaces on the status page, keys in the catalog.

## 3. Sidecars

Status: open

Goal: a content repository can bring a server-side component of its own for
logic that parts 1 and 2 do not cover. deepsplay starts it, supervises it and
makes it reachable for the repository's pages through a proxy. Pages stay plain
HTML; a backend is optional.

Starting point (from an earlier concept note, "Python sidecars with uv"):

- A sidecar is a separate process; deepsplay knows only its start command and
  its port. Python is attached through a normal HTTP server (WSGI apps behind
  gunicorn or waitress, ASGI apps such as FastAPI behind uvicorn).
- `uv` manages it: `uv.lock` pins every dependency, `uv` fetches the matching
  Python itself, `uv sync --frozen` creates the environment reproducibly, and a
  global cache speeds up repeated installs.
- The manifest gets a `[backend]` block with the start command, optionally the
  Python version, and the names of the secrets it needs (never values). Pages
  call the backend relative to the reserved path `/c/<config>/backend/`.
- The repository holds `pyproject.toml` and `uv.lock`; `.venv` and
  credentials stay out.
- The app reads its port from `PORT`, listens on `127.0.0.1` only, and reads
  only the secrets deepsplay passes in its environment.
- On a new revision: export and validate as before, then `uv sync --frozen`
  with the environment in the cache next to the revision (a venv is bound to
  path and platform; optionally shared per hash of `uv.lock`), start with a
  free `PORT` and the allowed secrets, supervise and restart on crash. The
  revision is published to screens only once the process is ready; if sync or
  start fails, the last working revision stays and the error shows on the
  status page. A newer revision replaces the process.
- The process lives as long as its configuration's revision is current, also
  when the page is not shown or no screen is connected (no start delay,
  background fetching possible; costs memory). A later option: lazy start with
  an idle timeout.

What has changed since that note, and has to be part of the plan:

- **Trust and isolation come first.** Running repository code is a different
  trust level than serving files, and deepsplay now runs in a container as an
  unprivileged user (ADR 13): it cannot switch users, and starting a container
  per sidecar would need the Docker socket (root on the host). Isolation is
  therefore at process level. Likely consequence: backends must be allowed
  explicitly per configuration in the host configuration, so only trusted
  repositories run code. This is the first decision of this part.
- **Container image**: needs `uv` (Python and packages are downloaded at
  runtime, so the container needs internet access); the `uv` cache belongs on
  the volume. Offline operation would need pre-built wheels.
- **Repository layout** (ADR 5, ADR 10): only `pages/` is delivered, so the
  backend code can live in a directory such as `backend/` next to the
  manifests and is never delivered. The `[backend]` block names that directory
  (the working directory with `pyproject.toml` and `uv.lock`).
- **Several manifests per repository**: likely one process per configuration,
  since secrets are per configuration; the code can still be shared.
- **Secrets** (ADR 8): the manifest names the secrets it wants; the host
  configuration allows them per configuration, like `upstreams`; the sidecar
  receives only those, as environment variables.
- **Publishing in two steps**: today `RevisionStore.publish` validates,
  renames and remembers in one go. With a backend: export, sync, start, wait
  until ready, then remember and announce.
- **Proxy reuse**: `/c/<name>/backend/*` forwards to `127.0.0.1:<port>` with
  the path checks, timeouts and size limits of the upstream proxy, without
  adding secrets.
- **Dev mode** (ADR 12): with `path =`, the sidecar runs from the directory
  with `uv run` and restarts when files in the backend directory change.
- **Existing hook**: a `[backend]` table in a manifest is already accepted and
  ignored with a warning on the status page.

Still open:

- How readiness is detected (port open, or a health path).
- Memory and CPU limits; in an unprivileged container at most `ulimit`, not
  cgroups.
- Final field names of the `[backend]` block (command, directory, Python
  version, secrets, lazy start).
