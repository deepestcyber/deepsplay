# Named backends

Status: proposed (2026-11-08)

A manifest can bring one backend today ([ADR 26](../adr/0026-sidecars.md),
`[backend]`, reached at `/c/<name>/backend/`). Repositories that collect
several unrelated pages end up with several unrelated server parts: a
showcase, a weather aggregator, a feed parser. Putting them all into one
Python app couples their dependencies, restarts and crashes: a broken
feed parser takes the weather box down with it. This unit lets a manifest
declare several backends by name, each its own process.

Background: [outline.md](../outline.md), [ADR 26](../adr/0026-sidecars.md),
[pages.md](../pages.md) "Backends".

Status values: `open`, `in progress`, `done`.

| # | Part | Status |
| --- | --- | --- |
| 1 | Manifest: `[backends.<name>]` | open |
| 2 | Processes and registry per backend | open |
| 3 | Proxy path `/c/<config>/backends/<name>/` | open |
| 4 | Environment and data directory | open |
| 5 | Publishing and the local watcher | open |
| 6 | Status page, catalog, `Deepsplay.backend()` helper | open |
| 7 | Docs: ADR, pages.md | open |

## Proposal in short

```toml
# unchanged: the unnamed backend, at /c/<config>/backend/
[backend]
dir     = "backend"
command = ["python", "app.py", "{port}"]

# new: named backends, each at /c/<config>/backends/<name>/
[backends.weather]
dir     = "backends/weather"
command = ["uvicorn", "app:app", "--host", "127.0.0.1", "--port", "{port}"]
health  = "/health"
secrets = ["weather_api"]

[backends.feeds]
dir     = "backends/feeds"
command = ["python", "-m", "feeds", "{port}"]
```

```js
const config = location.pathname.split("/")[2]
const data = await (await fetch(`/c/${config}/backends/weather/now`)).json()
```

- `[backend]` stays exactly as it is: same fields, path, environment and
  data directory. Existing repositories need no change.
- `[backends.<name>]` takes the same fields as `[backend]` (`dir`,
  `command`, `health`, `secrets`). A manifest may have `[backend]`, named
  backends, or both.
- Each backend is its own process with its own port, environment (from its
  own `uv.lock`), restarts and output. One failing does not affect the
  others' requests.

## 1. Manifest: `[backends.<name>]`

Status: open

- Names follow the upstream rule: `^[a-z0-9][a-z0-9_-]*$`, at most 64
  characters. `backends` must be a table of tables; anything else is an
  error, as for `[backend]` today.
- Each entry is parsed with `Deepsplay.Screen.Backend.parse/3` as it is,
  with error messages prefixed `backends.<name>` instead of `backend`.
- `dir` rules as today (not in `pages/`, with `pyproject.toml` and
  `uv.lock`). Two backends may share a `dir` (one project, two entry
  points); they then share the environment, since `env_dir` hashes the
  lock file already.
- `secrets` are checked against `backend_secrets` of the configuration per
  backend, so each backend gets only what it names.
- A limit on the number of backends per manifest, so a repository cannot
  start dozens of processes: proposal 8, in the host configuration as
  `backend_count` per `[[config]]` (default 8). `[backend]` counts as one.
- Without `backend = true`, `[backends.*]` is ignored with one warning, as
  `[backend]` is.

Considered and rejected:

- `[backend.<name>]`: clashes with the fields of `[backend]` (a backend
  named `dir` or `health`), and a manifest would have to choose one form.
- `[[backend]]` with a `name` field: an array cannot be mixed with the
  existing `[backend]` table, and order has no meaning here.

## 2. Processes and registry per backend

Status: open

- `Deepsplay.Backends` keys its state by `{config, name}` instead of
  `config`, with `nil` as the name of the unnamed backend. `current/1`,
  `stop/1`, `keep_only/1` and `all/0` take or return these keys;
  `ensure/4` gets the name (or the spec carries it).
- `Deepsplay.Backend` (the process) needs no change beyond receiving its
  name for the environment and the data directory.
- `backend_memory` applies per process, as today. The status page shows
  the sum next to the configuration, so an operator sees what several
  backends cost.

## 3. Proxy path `/c/<config>/backends/<name>/`

Status: open

- New route `scope "/c/:name/backends/:backend"` next to the existing
  one, to `DeepsplayWeb.BackendController.forward/2` with the backend
  name. Same methods, limits, timeouts and header rules.
- `/c/<config>/backend/` keeps reaching the unnamed backend only.
- Answers: `404` for an unknown name or a configuration without that
  backend, `503` while it is starting or restarting, as today.
- The upstream name used inside `UpstreamProxy` becomes `backend:<name>`,
  so the proxy statistics tell the backends apart.

## 4. Environment and data directory

Status: open

- New variable `DEEPSPLAY_BACKEND` with the backend's name (empty for the
  unnamed one), so a shared `dir` can tell its entry points apart.
- `DEEPSPLAY_DATA_DIR`:
  - unnamed backend: `state_dir/backends/<config>` as today;
  - named backend: `state_dir/backends/<config>.<name>`. Configuration
    names cannot contain `.` (`^[a-z0-9][a-z0-9_-]{0,63}$`), so the two
    never collide, and the unnamed backend's directory does not contain
    the named ones.
- Everything else as ADR 26: `PORT`, `HOME`, `UV_CACHE_DIR`,
  `DEEPSPLAY_CONFIG`, `DEEPSPLAY_URL`, the secrets this backend names.

## 5. Publishing and the local watcher

Status: open

- A revision is announced only once **all** its backends are ready
  (`Deepsplay.Revisions.publish_with_backend/2` waits for each). If one
  fails, the revision is not announced, the last good revision and all its
  backends keep running, and the status page names the failing backend.
  This keeps a revision's pages and backends consistent; a page never meets
  a backend from another revision.
- Backends of a revision start in parallel (each `uv sync` may take
  minutes); the overall limit stays per backend (10 minutes sync, 60
  seconds start).
- A backend whose spec and `uv.lock` are unchanged between revisions is
  still restarted with the new revision, as today, since its code may have
  changed. (Keeping it running when nothing in its `dir` changed would be
  an optimisation for later.)
- Backends that disappear from the manifest are stopped once the new
  revision is announced.
- Local watcher (`path =`): watches each backend's `dir` and restarts only
  the backend whose `dir` or block changed.

## 6. Status page, catalog, helper

Status: open

- Status page: one row per backend, `<config>` for the unnamed one and
  `<config> · <name>` for named ones, with state, revision, port, restarts,
  last crash and output as today.
- Catalog: the configuration lists its backends with name, `dir`, health
  path and state.
- Optional, small: `Deepsplay.backend(name, path)` in `deepsplay.js`,
  like `Deepsplay.api(upstream, path)`, returning
  `/c/<config>/backends/<name><path>` (or `/c/<config>/backend<path>`
  without a name), so pages do not parse `location.pathname`.

## 7. Docs

Status: open

- New ADR "Named backends" that amends ADR 26 (one process per backend
  instead of per configuration; the new path, variable, data directory and
  host limit). ADR 26 gets a note in its status section.
- pages.md "Backends": the `[backends.<name>]` form, the path, the helper,
  and that a revision is shown only once all its backends are ready.
- Host configuration docs: `backend_count`.

## Open questions

- Should `backend_count` exist at all, or is `backend = true` trust enough?
  The proposal keeps it as a guard against accidental process sprawl.
- Lazy start (ADR 26 consequences): with several backends per
  configuration, starting a backend on its first request becomes more
  attractive. Not part of this unit.
