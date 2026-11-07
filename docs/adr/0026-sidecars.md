# 26. Sidecars

Date: 2026-11-07

## Status

Accepted

## Context

Upstreams with caching (ADR 19, ADR 20) and shared state (ADR 21) cover most
needs of pages, but some logic must run on the server: combining several
APIs, parsing feeds, keeping a model. The outline reserved `[backend]` in
manifests and `/c/<name>/backend/*` for this. Running code from a repository
is a different trust level than serving its files, and deepsplay runs as an
unprivileged user in a container (ADR 13): it cannot switch users, and
starting containers would need the Docker socket, which is root on the host.

## Decision

A content repository can bring a backend: a Python process that deepsplay
installs with `uv`, starts, supervises and makes reachable for its pages.

Trust:

- A configuration runs a backend only with `backend = true` in its
  `[[config]]` in the host configuration; the default is off. Without it, a
  `[backend]` table is ignored with a warning on the status page, the
  revision is still shown, and calls to the backend answer `404`.
- Isolation is at process level only. Backends are for repositories whose
  authors are trusted with code on the server; the documentation says so.

The manifest:

```toml
[backend]
dir     = "backend"     # pyproject.toml and uv.lock; never inside pages/
command = ["uvicorn", "app:app", "--host", "127.0.0.1", "--port", "{port}"]
health  = "/health"     # optional
secrets = ["weather_api"]
```

- `dir` and `command` are required; `{port}` in `command` is replaced by the
  port. The Python version comes from the project (`requires-python`,
  `.python-version`). Only Python with `uv` for now; other runtimes can be
  added later.
- `secrets` names the secrets the backend wants (never values).

Lifecycle:

- One process per configuration (secrets are per configuration).
- A new revision is exported and validated, then `uv sync --frozen` creates
  its environment (in the cache next to the revision, shared per hash of
  `uv.lock`), then the process starts. The revision is remembered and
  announced only once the process is ready; until then, and if sync or start
  fails, the last working revision and its process keep running and the
  error shows on the status page.
- Ready means: `GET` on `health` answers `2xx`, or without `health`, the port
  accepts connections. Limits: 10 minutes for `uv sync`, 60 seconds for the
  start.
- The process runs as long as its revision is current, also without
  connected screens. The old process stops once the new one is ready.
- A crashed process restarts with backoff; after repeated crashes it is left
  stopped and the error shows on the status page.

Environment of the process, nothing else inherited:

- `PORT`, `HOME`, `UV_CACHE_DIR` (in `cache_dir/.uv`);
- `DEEPSPLAY_CONFIG` (the configuration's name), `DEEPSPLAY_URL` (to reach
  deepsplay, e.g. for shared state), `DEEPSPLAY_DATA_DIR` (a persistent
  directory per configuration under `state_dir`);
- the secrets the manifest names and the host allows for the configuration
  (`backend_secrets = [...]` in its `[[config]]`), as environment variables.

Limits, per configuration in the host configuration: `backend_memory` (e.g.
`"512MB"`, applied with `ulimit -v`; an unprivileged container offers no
cgroups). Requests to the backend have the timeouts and size limits of the
upstream proxy.

Proxy: `/c/<name>/backend/*` forwards to `127.0.0.1:<port>` with any method,
the path checks and limits of the upstream proxy, and no secrets added. No
WebSockets or server-sent events for now.

Visibility: the status page shows the process state, uptime, restarts and
the last lines of its output; the catalog shows the backend.

Development (ADR 12): with `path =`, the backend runs from the directory with
`uv run` and restarts when files in `dir` change.

Operations: the container image includes `uv`; Python and packages are
downloaded at runtime, so the container needs internet access. Offline
operation (pre-built wheels) is not covered.

## Consequences

- Repositories can add server logic in Python without a deployment of their
  own, and only where the host allows it.
- A trusted repository's backend can do anything the deepsplay user can:
  read the cache, other configurations' state and the secrets passed to it.
  Process-level isolation is not a security boundary.
- Publishing a revision with a backend takes longer (sync and start) and
  depends on the network for new dependencies.
- Always-on processes cost memory per configuration; a lazy start can be
  added later.
