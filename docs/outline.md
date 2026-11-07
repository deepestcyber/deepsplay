# Display App – Concept & Implementation Brief

Nov 6, 2026 · @kratenko

## Overview and goals

The display app is a Phoenix server that shows independent HTML pages on kiosk screens and takes its content from git repositories. A repository is checked out once per revision and shared by every screen that uses it. When the branch moves, running screens pick up the new revision on their own.

Goals of phase 1:

- Show a default repository on `/` and other configurations under their own URLs.
- Rotate through the pages of a repository, with the rotation defined in the repository.
- Keep secrets on the server so that repositories can be public.
- Keep showing the last working version when anything fails, and say what is wrong.
- Leave room for server-side components (sidecars) in any language, without building them yet.

## Decisions already made

| Topic | Decision |
| --- | --- |
| Stack | Elixir and Phoenix, LiveView where it makes sense (screen shell, status page) |
| Pages | Plain HTML from the repository; no server-side components in phase 1 |
| Config format | TOML for host config and for the manifest in the repository |
| Repository cache | One checkout per repository and revision, reused by all screens, kept across restarts |
| Updates | The host polls branches; running screens switch to a new revision automatically |
| Rotation | Runs in the browser; screens are not synchronized |
| Failure | Keep serving the last working revision; a fallback page reports the problem when there is nothing to show |
| Reporting | A status page, no alerts for now |
| Configurations | Default configuration on `/`, others by name; restrictions on which repositories may be shown come later |
| Secrets | Stored on the host, used by pages through the server, never part of the repository |
| Screen identity | A screen only chooses a configuration; no per-screen settings in phase 1 |
| Git access | The `git` command line tool, installed in the container |

## Architecture

&#91;embedded content: architecture · 8 parts\]

The poller, cache, web endpoint and upstream proxy run in one Phoenix app. The poller fills the cache and announces new revisions; screens get the plan and the pages from the web endpoint and reach outside services only through the proxy.

| Component | Responsibility |
| --- | --- |
| Poller | Per repository and ref: detect new SHAs, fetch, export, validate, publish |
| Repo cache | Immutable export per SHA on disk, with retention and cleanup |
| Web endpoint | Serves the LiveView shell, the files of a revision and the status page |
| Upstream proxy | Forwards page requests to host-defined upstreams with credentials added |
| Host secrets | Credentials for git and upstreams, outside any repository |

## Repository cache

The cache is keyed by the resolved commit SHA, never by branch or tag name, because branches and tags move. Each repository gets its own directory:

```text
<cache_dir>/
  <repo-key>/              # derived from the repository URL
    mirror.git/            # bare repository, shallow fetches only
    rev/<sha>/             # exported tree of one revision, read-only, no .git
    refs/<ref>             # last good SHA for a branch (one small file)
    tmp/                   # work in progress, emptied on start
```

Rules:

1. **One writer per repository.** A supervised process per repository serializes fetches. Requests for the same revision wait for the running fetch instead of starting another.
2. **Fetch, then export.** Fetch the ref with depth 1 into `mirror.git`, export the commit with `git archive` into `tmp/`, validate it, then move it to `rev/<sha>/` with one atomic rename. A half-written revision is never visible.
3. **Reuse.** If `rev/<sha>/` exists, nothing is fetched. All screens and all configurations on the same repository and SHA share it.
4. **Persist across restarts.** The cache directory lives on a persistent volume. On start, the server serves the last good SHA from `refs/` before the first poll finishes, so a restart without network still shows content.
5. **Retention.** Keep the current SHA of every ref in use plus the previous 3 SHAs per repository, so screens that are still on an older revision can finish loading it. Delete older revisions. Delete a whole repository directory once no configuration refers to it; this check runs at start and once a day.
6. **No `.git` in served files.** Pages are served from the export, so the repository history is never reachable over HTTP.

## Configurations

A configuration says which repository, ref and secrets a screen shows. The default configuration is served on `/`; every other one is defined on the server and served on `/c/<name>`. In phase 1 a URL can only select a configuration that the host defined, never name an arbitrary repository. An unknown name shows the fallback page.

Host configuration (TOML, outside any repository):

```toml
[server]
cache_dir      = "/var/lib/display/cache"
default_config = "lobby"
poll_interval  = "30s"      # per repository and ref, with jitter
keep_revisions = 3          # previous revisions kept per repository
upstream_cache_size = "200MB"   # upstream answers, in memory and on disk
repo_upstreams      = true      # manifests may declare upstreams without secrets
repo_upstream_hosts = []        # ... for these hosts only, e.g. ["*.dwd.de"]; empty: any
shared_state        = true      # shared state for pages (ADR 21)
state_dir           = "/var/lib/display/state"   # default: <cache_dir>/.state

[[config]]
name      = "lobby"
repo      = "https://github.com/example/lobby-screen.git"
ref       = "main"          # a branch is polled; a tag or SHA is resolved once
subdir    = ""              # optional: root (manifests and pages/) is a subdirectory
manifest  = "screen.toml"   # optional: manifest path below the root
params    = { theme = "dc" }  # optional: default parameters for its pages (ADR 16)
upstreams = ["weather"]     # upstreams (see Secrets) this configuration may use

[[config]]
name       = "kitchen"
repo       = "git@github.com:example/private-screens.git"
ref        = "kitchen"
credential = "github_deploy_key"   # host secret used to fetch this repository
```

In development, a configuration can use `path = "/abs/dir"` instead of `repo` and `ref`: the directory is served live, and every save shows on screen at once (ADR 12).

Several configurations may point at the same repository and ref. They share one poller and one cache entry. With different `manifest`s they can show the same pages in different rotations; with different `subdir`s they are separated and cannot reach each other's files.

## Repository content format

The root of a configuration is the repository, or its `subdir`. Below it:

```text
<root>/
  screen.toml               default manifest
  rotations/kitchen.toml    further manifests, anywhere except pages/
  pages/                    the only directory that is delivered
    welcome/index.html
    weather/index.html
  README.md, .gitignore, …  never delivered
```

Only files in `pages/` are delivered; hidden files and directories (names starting with `.`) inside it are not. A manifest lists pages by their path relative to `pages/`, and how they rotate: `sequential` (default) shows them in listed order, `random` picks the next page weighted by `weight` (default 1.0) and never shows the same page twice in a row when there is more than one. Weights are ignored in sequential rotation. Further rotation rules, such as time windows, are still open.

```toml
title    = "Lobby"
rotation = "random"                # "sequential" (default) or "random"
duration = "30s"                   # optional default display time; without it 15s

[params]                           # optional default parameters for pages that declare them
theme = "neon"

[[page]]
path     = "welcome/index.html"    # file in pages/; may add a query, e.g. "?duration=30s"
weight   = 3.0                     # optional, > 0, default 1.0; random rotation only

[[page]]
path     = "weather/index.html"
duration = "45s"                   # optional, overrides the manifest's duration
uses     = ["weather"]             # upstreams this page calls through the server
```

Validation runs on every new revision, before it is published:

- The manifest parses, is smaller than a size limit, and contains at least one page.
- `pages/` exists, and every `path` names a regular, non-hidden file in it. A query string on a path is passed on to the page; only the file part is checked.
- `rotation` is `sequential` or `random`; every `weight` is a number greater than 0; every `duration` (of the manifest or a page) is a valid duration. A page without `duration` uses the manifest's, or 15 seconds.
- Every `uses` entry is an upstream the configuration is allowed to use. Otherwise the revision is rejected, not served with a broken page.
- A `[backend]` table is ignored with a warning on the status page (see Extension points for sidecars).

A revision that fails validation is never published. The previous good revision stays on screen.

## Refresh and polling

There is one poller per repository and ref, no matter how many configurations or screens use it. It checks every `poll_interval` (default 30 seconds) with a random offset of about 20 percent so pollers do not fire together.

- **Check:** run `git ls-remote <url> refs/heads/<ref> refs/tags/<ref>` for every host, GitHub included: one light request that returns only the SHA and transfers no objects.
- **Changed SHA:** fetch with depth 1, export, validate, then publish the new revision (see Repository cache). Publishing sends a message on Phoenix PubSub for every configuration that uses this repository and ref.
- **Errors:** retry with exponential backoff up to 5 minutes, and record the last result for the fallback and status pages. A SHA that failed validation is not retried until the branch moves again.
- **What is polled:** branches only. A tag or a full SHA is resolved once at start and when the server restarts.
- **Credentials for private repositories:** a host secret, either an HTTPS token or an SSH deploy key. It reaches git through the environment (`GIT_ASKPASS`, `GIT_SSH_COMMAND` with a key file), never on the command line, in logs or in the repository. Git always runs with `GIT_TERMINAL_PROMPT=0` and a timeout.

Webhooks are not needed. They could be added later as an extra trigger for the same poller.

## Screens and LiveView

A screen opens `/` or `/c/<name>` in a browser in kiosk mode. The page it receives is the shell, a LiveView that holds the rotation and shows each page in an iframe.

- **Rotation runs in the browser.** The server sends the plan (revision, rotation strategy, and a list of page URLs with durations and weights). A small JavaScript hook in the shell cycles through it, in order or weighted at random. The next page loads only when it is due, so its animations start when it is shown; the old page stays visible until then and is cleared after the crossfade. A screen that loses its connection keeps rotating, and screens are not synchronized with each other.
- **Revision in the URL.** Pages are served from `/c/<name>/r/<sha>/<path>`, where `<path>` is relative to `pages/`. Files of one revision never change, so they can be cached for a long time, and a screen that is still on the old revision keeps loading its files while the new one is published.
- **Pinned page.** `/?page=<path>` or `/c/<name>?page=<path>` shows one file of the revision without rotating (ADR 11). The path is relative to `pages/`; any deliverable file can be pinned, not only listed pages. A new revision reloads the pinned page.
- **Live update.** When the poller publishes a new revision, every LiveView of that configuration receives the new plan and applies it at the next page change.
- **Reconnect.** LiveView reconnects by itself after a server restart or a network break and then receives the current plan. Until then the screen continues with the plan it has.
- **No pointer.** The shell sets `cursor: none`, and the iframes take no pointer input, so the pointer is hidden on every page. Pages get no mouse or touch input. Hiding the pointer in the operating system as well covers the moment before the shell loads.

### Status page

`/status` is a LiveView based on Phoenix Presence. Each screen reports its configuration, current revision, current page and a heartbeat. The page shows:

- every configuration with its current revision, the time of the last poll and its result;
- the connected screens and when each was last seen;
- the most recent errors (poll failures, rejected revisions, proxy failures), kept in memory.

There are no alerts in phase 1.

## Secrets

Anything the browser can read is not secret, so a page can never hold a key in its HTML or JavaScript. Secrets are used by the server on the page's behalf, through named upstreams that the host defines. The repository only names the upstream it wants to call.

1. **Host secrets.** Values live in a secrets file outside the repository and the cache (TOML at `DEEPSPLAY_SECRETS`, mode 0600, mounted read-only) or in environment variables `DEEPSPLAY_SECRET_<NAME>`. Names are lowercase, for example `weather_api`.
2. **Host upstreams.** The host defines each upstream: a base URL and how the secret is added to the request, as a header and/or a query parameter. A page cannot choose a URL, so a repository cannot make the server send a secret to a host of its own.
3. **Binding.** A configuration lists the upstreams it may use (`upstreams` in the host configuration). A repository that asks for anything else is rejected at validation.
4. **Use.** A page calls `/c/<config>/api/<upstream>/<path>`. The server checks the binding, adds the credential, forwards the request and returns the answer.

```toml
# secrets.toml (host only, never in a repository)
weather_api = "..."

# host configuration
[upstream.weather]
base_url  = "https://api.example.com/v1"
methods   = ["GET"]
header    = "Authorization"
value     = "Bearer {secret:weather_api}"
# query       = "appid"                    # alternatively or additionally,
# query_value = "{secret:weather_api}"     # the secret as a query parameter
cache_ttl = "60s"       # one upstream call serves all screens within this time
stale_ttl = "1h"        # optional: serve the old answer this long while the upstream fails
refresh   = true        # optional: fetch answers screens use again before they expire
```

The proxy:

- joins the path to `base_url` after normalizing it and rejects `..` and absolute URLs;
- forwards only the listed methods and drops cookies and the client's `Authorization` header;
- applies timeouts and a response size limit;
- caches answers for `cache_ttl`, which keeps many screens from using up an upstream rate limit; concurrent requests share one upstream call, with `refresh` answers screens still use are fetched again before they expire, and with `stale_ttl` an expired answer is served while the upstream fails (ADR 20).

Secret values are never logged, never shown on the status page (only names) and never substituted into served files. Credentials for fetching private repositories come from the same secrets file.

## Failure behavior and fallback page

A screen never goes blank while any good revision exists. The server keeps the last good revision and reports the problem on the status page.

| Situation | Behavior |
| --- | --- |
| Poll fails (network, rate limit) | Keep serving the current revision, retry with backoff, show the error |
| New revision fails export or validation | Reject it, keep the last good revision, remember the SHA so it is not retried until the branch moves |
| Server restarts without network | Serve the last good revision from the cache on disk |
| First start, empty cache, no network | Show the fallback page until the first revision arrives |
| Unknown configuration name | Show the fallback page with that message |
| Pinned page does not exist in the current revision | Show the fallback page with that message |
| Upstream call fails | Return an error to the page (502 or 504); the page decides how to show it |

The fallback page is built into the app. It is the shell in a state without a revision, not a separate route, so it switches to the real content by itself as soon as the first revision is published. It shows the configuration name, repository and ref, the last error with its time, and when the next attempt happens. Error texts have credentials and tokens removed from URLs.

## Security notes

In phase 1 every repository is trusted, because only the host defines configurations. These rules still apply from the start, since they are hard to add later:

- **Paths and symlinks.** Files are served only from `pages/` of `rev/<sha>/` (or its `subdir`). Paths with `..`, absolute paths and hidden files are rejected. Symlinks in a repository can point outside the checkout, so the revision is rejected at export, and file access never follows a symlink.
- **Git transports.** Only `https` and `ssh` URLs are allowed (`GIT_ALLOW_PROTOCOL=https:ssh`). No `file://`, no submodules, no LFS, and no repository hooks.
- **No repository code on the server.** The manifest is parsed as data (TOML with a size limit). Nothing from a repository is evaluated as Elixir.
- **Response headers.** Static files are served with `X-Content-Type-Options: nosniff` and the type derived from the file extension.
- **Proxy reach.** The proxy has no login. Anyone who can reach the server can call an upstream that a configuration may use, so upstreams should be read-only (`GET`) and the server should stay on the internal network.
- **One origin.** All pages share the server's origin, so a page can call the proxy paths of other configurations. This is acceptable for trusted repositories. Before untrusted repositories are shown, pages need separate origins or sandboxed iframes.
- **Restrictions deferred.** Limiting which repositories can be displayed (allowlists, authentication for dynamic configurations) comes after phase 1.

## Extension points for sidecars

Sidecars are not part of phase 1, but the architecture should not block them. A sidecar would be a process in any language, started and supervised by the app, that a page reaches over HTTP through the server.

- **Reserved names.** `backend` is reserved as a manifest table and as the URL prefix `/c/<config>/backend/*`. In phase 1 a `[backend]` table is ignored with a warning.
- **Immutable revision directories.** A sidecar can later run from `rev/<sha>/`, because that directory never changes. Everything per revision is identified by `(repo-key, sha)`.
- **Supervision.** One `DynamicSupervisor` entry per configuration and revision, started with a command from the manifest, a `PORT` from the app and only the secrets the configuration allows. It is restarted on crash and replaced when a new revision is published.
- **Proxy reuse.** The path checks, timeouts and size limits of the upstream proxy apply to sidecars as well.
- **Isolation.** Running repository code is a different trust level than serving files. Before sidecars exist, decide how they are isolated (separate user or container) and which repositories may have them.

Keeping the proxy and the revision store behind small modules (`Upstream`, `RevisionStore`) is enough preparation for now.

## Deployment and kiosk setup

**Server**

- A container image, built by GitHub Actions for amd64 and arm64 and published on `ghcr.io/deepestcyber/deepsplay` (ADR 13). It contains the release, `git`, `openssh-client` and CA certificates, and runs as a non-root user.
- Persistent volume for `cache_dir`. The host configuration and the secrets file are mounted read-only.
- Settings through environment variables: the path of the host configuration, the secrets path or values, `SECRET_KEY_BASE`, `PORT`, optionally `DEEPSPLAY_ORIGINS`. Plain HTTP; HTTPS through a reverse proxy.
- Setup with Docker Compose or NixOS `virtualisation.oci-containers`: see [deployment.md](deployment.md).

**Screen**

- Chromium in kiosk mode, started by systemd and restarted on crash. Typical flags: `--kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --autoplay-policy=no-user-gesture-required`.
- The start URL is `/` or `/c/<name>` of the server.
- Hide the pointer in the operating system, for example with `unclutter` on X11 or a kiosk compositor such as `cage` on Wayland. The shell hides it on all pages once loaded.
- Turn off screen blanking and power saving.

## Phase 1 scope

In scope:

- [ ] Host configuration in TOML with a default and named configurations
- [ ] Repository cache: SHA-keyed exports, retention, kept across restarts
- [ ] Branch poller with `git ls-remote`
- [ ] Manifest parsing and validation
- [ ] LiveView shell with browser-side rotation, page pinning and live revision updates
- [ ] Static file serving from the revision directory with path and symlink checks
- [ ] Upstream proxy with host-side secrets and a response cache
- [ ] Status page with Presence
- [ ] Fallback page for missing content and errors
- [ ] Release and container setup, kiosk notes

Out of scope for now:

- Sidecars (server-side components in other languages)
- Restrictions on which repositories may be shown, and authentication for dynamic configurations
- Alerts
- Screen synchronization and per-screen settings
- Webhooks as a refresh trigger
- Git submodules and LFS
- Rotation rules beyond sequential and weighted random order (such as time windows)

## Open decisions

| Question | Proposed default |
| --- | --- |
| Further rotation rules in manifests (time windows, conditions) | Sequential or weighted random with a duration per page for now; extend when needed |
| When a new revision replaces the running one | At the next page change; an immediate reload could become an option |
| Who may open `/status` | Reachable only on the internal network; add basic authentication if needed |
| Methods an upstream may use | `GET` only unless the host lists more |
| Number of kept revisions | 3 previous per repository, set in `keep_revisions` |
| Tags and fixed SHAs | Resolved at start, not polled |
| Model for restricting repositories | Decide before dynamic configurations are added (allowlist by host or organization, authentication) |
| Where the secrets file lives and who maintains it | A file outside the repository, mode 0600; replace with a secret store later if one is in use |
