# 21. Shared state for pages

Date: 2026-11-07

## Status

Accepted

## Context

Pages sometimes need state that outlives a page view and is the same on every
screen: a counter, a message set by one page and shown by another, the last
item of a list. `localStorage` is per display only. Pages should get such
state without a server component of their own (sidecars, phase 3 part 3).

Pages run in the browser on one origin and can call any URL, so borders
between pages, configurations or repositories cannot be enforced; separation
is a matter of organisation, as for the upstream proxy (ADR 8).

## Decision

deepsplay keeps small JSON values per namespace and offers them to pages over
HTTP.

Namespaces and keys:

- State is shared by all pages of a namespace, not kept per page.
- The server derives the namespace from the configuration; pages never pass
  it. Default: the content root, i.e. repository, ref and `subdir`, or the
  path of a local directory. Configurations showing one repository and ref
  with different manifests share state; other repositories and refs stay
  apart.
- A configuration can set `state = "<name>"` in the host configuration to
  use a named namespace (its own, or one shared deliberately), or
  `state = false` to have none.
- Keys: 1 to 200 characters, segments of `A-Z a-z 0-9 . _ -` separated by
  `/`, no empty segments and none starting with `.`. Recommended convention:
  `<page>/...` for one page's state, `shared/...` for state several pages
  use.

API, at `/c/<config>/state/` (added to ADR 10):

- `GET <key>`: the JSON value with `ETag: "<version>"`, or `404`.
- `PUT <key>` with a JSON body: stores it, answers with the new version.
  Last write wins; with `If-Match: "<version>"` only if the version is
  unchanged (`412` otherwise), with `If-None-Match: *` only if the key does
  not exist.
- `DELETE <key>`: `204`.
- `POST <key>` with `{"increment": n}`: adds `n` to a number atomically; a
  missing key counts as 0.
- `GET ?prefix=<prefix>`: keys with their versions, without values.
- Each key has a version that increases with every write.
- No live updates: pages poll. Server-sent events can be added later.

Page helper: `deepsplay.js` gets `Deepsplay.state` with `get`, `set`,
`delete`, `increment`, `list` and `update(key, fn)` (read, change, write
with `If-Match`, retried on conflict), building URLs for the page's
configuration like `Deepsplay.api`.

Limits: a value at most 64 KB (`413`), a namespace at most 1000 keys and
5 MB (`507`). Fixed for now.

Persistence:

- A server setting `state_dir`, default `<cache_dir>/.state/` (hidden, so the
  cache cleanup of ADR 6 leaves it alone). State is data, not cache; a
  separate `state_dir` lets it be kept and backed up on its own.
- One JSON file per namespace with keys, values and versions, written at
  most a second after a change (temporary file, then rename); a crash can
  lose the last second.

Trust and switches:

- No login and no write token: a token would be part of the page and
  readable by anyone on the network. State is neither secret nor protected;
  anyone on the internal network can change it, and pages must cope with any
  value.
- A server setting `shared_state = true | false` (default `true`) and
  `state = false` per configuration switch it off.
- Local directories (ADR 12) use the same store, with their path as
  namespace.

Visibility: the status page lists namespaces with key count, size, the
configurations using them and the last write; the catalog shows the
configuration's namespace with its keys and shortened values, read-only.

## Consequences

- Pages get shared, persistent state with a few lines of JavaScript and no
  server code.
- Pages of one repository share state across configurations and rotations;
  deliberate sharing across repositories needs a named namespace.
- Anyone who reaches the server can read and change state; it suits display
  state, not anything that must be trusted.
- Polling delays changes by the poll interval and costs a request per page
  and interval.
- Moving or deleting `state_dir` loses the state; it belongs in backups.
