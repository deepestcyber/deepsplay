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
| 1 | Upstream cache for expensive and rate-limited providers | in progress |
| 2 | Shared state for pages | open |
| 3 | Sidecars | open |

## 1. Upstream cache for expensive and rate-limited providers

Status: in progress (decided, not built)

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
  `cache_dir/upstream/`, loaded again on start (wall-clock expiry).
- **Status page**: per upstream origin, entries, hits, misses, stale answers,
  last fetch and error; total size against the limit.

ADR 19 details: server settings `repo_upstreams` (default `true`) and
`repo_upstream_hosts` (patterns `dwd.de`, `*.dwd.de`), overridable per
configuration; resolved addresses all checked, connection to a checked
address with the host name for TLS and `Host`.

Planning is complete; next is building.

## 2. Shared state for pages

Status: open

Goal: pages can keep small state on the server, shared by all screens of a
configuration, without a server component of their own.

Already clear:

- State per display needs no server: the browser's `localStorage` is shared by
  a screen's pages (they share one origin) and survives reloads as long as the
  kiosk browser keeps its profile. Phase 2 (repository conventions) recommends
  a key prefix per page.

To plan:

- **Scope**: per configuration (likely, as for secrets and upstreams) or per
  repository root shared by configurations with different manifests.
- **API**: e.g. `GET`, `PUT` and `DELETE` on `/c/<name>/state/<key>` with JSON
  values; key format; listing keys. A new reserved path in ADR 10.
- **Limits**: size per value and per configuration, number of keys.
- **Persistence**: in `cache_dir`, surviving restarts and deploys; format and
  write strategy.
- **Concurrent writes**: last write wins, or additionally compare-and-set and
  atomic increment for counters.
- **Live updates**: pages subscribe to keys (e.g. server-sent events) so every
  screen sees a change at once, or pages poll.
- **Trust**: without login, anyone on the internal network can write. Whether
  limits are enough, or a write token per configuration is needed.
- Dev mode with local directories (ADR 12): same store, or one that is reset.

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
