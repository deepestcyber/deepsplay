# Building content repositories

A content repository holds what deepsplay shows: plain HTML pages and a
manifest saying how they rotate. deepsplay fetches it from git, serves it to
the screens and picks up new commits on its own.

The quickest start is the template repository
[deepestcyber/deepsplay-template](https://github.com/deepestcyber/deepsplay-template):
create your own repository from it ("Use this template" on GitHub) and add it
to the host configuration:

```toml
[[config]]
name = "lobby"
repo = "https://github.com/you/lobby-screen.git"
ref  = "main"
```

The screen at `http://<server>:4000/c/lobby` then shows your pages, and
`/catalog/lobby` documents them.

## Layout

```text
screen.toml              the manifest: which pages, how they rotate
rotations/*.toml         further manifests (optional, see the last section)
README.md
pages/                   everything the screens get; nothing else is served
  clock.html             a simple page: one file
  life/                  a larger page: its own folder
    index.html
    cells.js
  shared/                this repository's helpers (theme, scripts, styles)
  assets/                shared fonts, images, videos, with their licences
```

Only files in `pages/` are delivered, and no hidden files (names starting with
`.`) or symlinks. Manifests, the README and any other directory stay private.
Use lowercase file names with dashes.

## The manifest

`screen.toml` lists the pages and how they rotate:

```toml
title       = "Lobby"
description = "Daytime rotation for the lobby screens."   # optional
rotation    = "sequential"     # or "random"
duration    = "20s"            # display time of pages without their own; default 15s

[params]                       # default parameters for pages that declare them
theme = "dark"

[[page]]
path = "welcome.html"

[[page]]
path        = "life/index.html?cells=40"   # a query is passed on to the page
duration    = "45s"
weight      = 2.0              # random rotation only: shown more often
description = "Large cells, readable from the door"   # optional: why this entry
```

- `rotation = "random"` picks the next page weighted by `weight` (default 1.0)
  and never shows the same page twice in a row.
- Durations are whole numbers with `ms`, `s`, `m` or `h`.
- A page that calls an upstream (see below) lists it: `uses = ["weather"]`.
- `description` (optional, at most 500 characters) says what a rotation or
  an entry is for; the catalog shows it. The page's own description belongs
  in its parameter block (below).
- `enabled = false` switches an entry off (also overrides and `glob`
  entries) without deleting it. It is still checked, never shown, and listed
  under "Disabled entries" in the catalog.

### Many pages with one entry

An entry can name its pages with `glob` instead of `path`; each page found
becomes an entry of its own, with the entry's other fields:

```toml
[[page]]
glob     = "small/*.html"
exclude  = ["small/draft-*.html", "small/old.html"]   # optional
query    = "theme=neon"                               # optional, for each page
duration = "20s"
when     = { from = "08:00", until = "20:00" }
```

- Patterns are relative to `pages/`: `*` and `?` match within a directory,
  `**` across directories (`small/**`), `{a,b}` alternatives. Only `.html`
  files count.
- `exclude` (a pattern or a list) leaves pages out; `exclude` and `query` are
  only allowed with `glob`.
- Fragments (`page = false`) are left out, and so are files that have an
  entry with `path`: give a single page its own settings that way, or take
  it out with `enabled = false`.
- The pages are inserted where the entry stands, in alphabetical order. In a
  random rotation each has the full `weight`; a smaller one keeps a large
  directory from taking over.
- A new file that matches is in the rotation with the next revision, without
  changing the manifest. The catalog shows the pages found, marked with
  their pattern; a pattern that finds nothing is a warning.
- Overrides always name one page with `path`.

### Time windows and overrides

Pages can be limited to times with `when`; overrides interrupt the rotation
during their windows:

```toml
when_empty = "black"           # or a page path: shown when no page is active

[[page]]
path = "night.html"
when = { from = "22:00", until = "06:00" }   # overnight

[[page]]
path = "payday.html"
when = [{ dates = "13..15" }, { dates = "12-24", until = "14:00" }]

[[override]]
path     = "fire-drill.html"
when     = { start = "2027-03-04 10:00", end = "2027-03-04 10:15" }
priority = 10                  # optional, default 0; higher wins

[[override]]
path = "lunch.html?menu=today"
when = { days = "mon-fri", from = "11:45", until = "12:00" }
```

A window can have these fields; all it has must match, and a list of windows
matches if any does:

| Field | Meaning |
| --- | --- |
| `start`, `end` | one continuous period: `YYYY-MM-DD`, `YYYY-MM-DD HH:MM` or `YYYY-MM-DD HH:MM:SS`; either may be left out |
| `dates` | `YYYY-MM-DD`, `MM-DD` (every year) or `DD` (every month); ranges with `..`; a list |
| `days` | `mon` to `sun`, a range (`"mon-fri"`) or a list |
| `from`, `until` | daily time `HH:MM` or `HH:MM:SS`; `until` before `from` runs overnight; `"24:00"` ends the day |

- Dates are always ISO, times always 24-hour, in the screen's local time;
  screens need a correct clock. A start is included, an end excluded.
- At each page change, the next page is chosen among the active ones. A
  page whose window closes finishes its display time; a single active page
  stays without reloading; with none active, `when_empty` applies.
- Seconds are optional (`"11:59:30"`); screens then check at every full
  second instead of every full minute. They are as precise as the screens'
  clocks, so keep those synchronised (NTP).
- An override starts at once when its window opens, and the rotation
  continues with the interrupted page when it ends. Of several active ones,
  the highest `priority` wins, the first of equal ones. A parameter with
  `from = "duration"` gets the remaining time of the window. Pinned pages
  ignore overrides.
- The catalog shows each entry's windows and whether it is active now (in
  the server's local time), and lists the overrides.

A revision whose manifest is invalid (or names missing files) is never shown;
screens keep the last good one, and `/status` says what is wrong.

## Pages

A page is a complete HTML document shown full screen in an iframe. It can use
any HTML, CSS and JavaScript. deepsplay offers a small helper for the common
parts, which pages may use or ignore.

### Documenting a page and its parameters

A page describes itself and its URL parameters in a block in its `<head>`:

```html
<head>
<title>Game of Life</title>
<script type="application/toml" id="deepsplay-page">
description = "Conway's Game of Life over the whole screen."
details     = """
Cells live with two or three neighbours and are born with three.

- the screen wraps around at the edges
- a stale pattern is replaced by a new random one
"""                                     # optional: longer explanation
author      = "Ada Lovelace"            # optional; or ["Ada", "Grace"]
credits     = "Rules by John Conway"    # optional: data and assets used
license     = "MIT"                     # optional: the page's own license
uses = ["theme"]

[params.cells]
type        = "int"
default     = 90
min         = 4
description = "Cells along the shorter side of the screen."

[params.gps]
type        = "number"
default     = 10
description = "Generations per second."

[[variants]]
label = "Large cells, slow"
query = "cells=40&gps=4"
</script>
<script src="/lib/v1/deepsplay.js"></script>
```

- Parameter types: `string`, `int`, `number`, `bool`, `duration` (as in
  manifests), `color` (hex or a colour name), `enum` (with `values`).
  Optional: `default`, `min`, `max` (numbers; durations as text such as
  `"500ms"`), `description`.
- `variants` are example settings; the catalog offers them as links.
- `page = false` marks a file in `pages/` that is not a page on its own, such
  as a fragment another page loads. It is still served, but not offered as a
  page.
- `title` is optional; the page's `<title>` is used otherwise.
- `description` is one short sentence; the catalog's overview shows it.
  `details` is optional, for anything longer: where the page comes from, how
  it behaves, how to use its parameters. Plain text, line breaks are kept;
  the catalog shows it collapsed. Helpers can have it too.
- `author`, `credits` and `license` are optional and shown in the catalog.
  `credits` attributes data and assets (e.g. "Radar: Deutscher
  Wetterdienst"); `license` is preferably an SPDX identifier. Helpers can
  have them too.
- The block must not contain the text `</script`.

Problems in the block never stop a page from being shown; they appear as
warnings in the catalog.

### Reading parameters

With the helper loaded, a page reads its parameters typed, with defaults
applied and limits enforced:

```js
const P = Deepsplay.params()
// life/index.html?cells=40  →  { cells: 40, gps: 10 }
```

Values that are invalid for their type fall back to the default; parameters
without a value and without a default are left out. The helper is
`/lib/v1/deepsplay.js` (compatible within `v1`); a page can pin one exact
version with `/lib/deepsplay@X.Y.Z.js`, or copy the file into the repository.
Pages using it work only when served by deepsplay.

A page (or its theme) reads its metadata with `Deepsplay.page()`:

```js
const { title, description, details, authors, credits, license } = Deepsplay.page()
// authors is always a list; details, credits and license are null when not set
if (authors.length) credit.textContent = "by " + authors.join(", ")
```

Whether a credit appears on screen is up to the page or its theme, e.g.
through a theme parameter.

### Shared helpers

A script used by several pages, such as a theme, defines its parameters once,
in its own code:

```js
// pages/shared/theme/theme.js
const T = Deepsplay.helper("theme", `
[params.theme]
type    = "enum"
values  = ["dark", "light"]
default = "dark"

[params.duration]
type = "duration"
from = "duration"
`)
```

`Deepsplay.helper` returns the helper's parameters right away, before the page
is painted. Pages list the helpers they use (`uses = ["theme"]`) and load
`deepsplay.js` first, then the helper, then their own code. A page reads a
helper's values with `Deepsplay.params("theme")`. If a page and a helper
define the same parameter, the page's definition counts.

### Parameters deepsplay adds

deepsplay adds values to the page URLs it builds, for parameters a page
declares (itself or through a helper) but does not set in its own query:

1. the configuration's `params` in the host configuration,
2. the manifest's `[params]`,
3. for a parameter with `from = "duration"`: the page's display time.

The first valid one counts; the definition's `default` applies otherwise. So a
repository can look different per screen (`params = { theme = "light" }`)
without changing its pages, and a progress bar gets its time without repeating
it in the manifest. A pinned page gets the same values, but no display time.

### Ending a page early

A page with a natural end (a game that finishes, a video, a slideshow of a
varying number of pictures) tells the screen when it is done:

```js
Deepsplay.done()
```

Its `duration` then is an upper limit: the screen moves on at `done()` or
when the display time is over, whichever comes first.

- Rotation page: the next page follows, as at the end of the display time.
  If that is the same page (one active page, a pinned page, the `when_empty`
  page), it is loaded again and starts fresh.
- Override: it ends on this screen until its window closes; a lower override
  that is still active, or the rotation with the interrupted page, comes
  back.
- A page is shown at least 2 seconds after it has faded in; an earlier
  `done()` takes effect then. A page calling `done()` at once is shown for
  2 seconds at a time.
- Only the visible page counts, and only on its own screen; other screens go
  on as before.
- Outside a screen (opened on its own, in the catalog) nobody listens and
  `done()` has no effect. Try it with a pinned page (`?page=`).

`done()` is newer than deepsplay 0.4.0. A screen can still hold an older
`deepsplay.js` for a while after an update (about an hour, longer while it
cannot reach the server), so a page that should also run there checks first:

```js
if (Deepsplay.done) Deepsplay.done()
```

### External data

Pages call external APIs through deepsplay rather than directly, so all
screens share one cached answer and pages never contain API keys:

```js
const url = Deepsplay.api("weather", "/current?city=berlin")
const data = await (await fetch(url)).json()
```

`Deepsplay.api` builds the right URL for the page's configuration, however
deep the page lies in `pages/`. The page lists the upstream in its `uses` in
the manifest.

There are two kinds of upstreams:

- **Upstreams of the host**: defined in the host configuration, with secrets
  if the API needs a key, and allowed per configuration.
- **Upstreams in the manifest**: open APIs without keys can be declared by
  the repository itself:

  ```toml
  [upstream.radar]
  url            = "https://maps.dwd.de/geoserver/dwd/wms"
  cache_ttl      = "5m"           # required, at least 1m
  stale_ttl      = "1h"           # optional: serve the old answer while the API fails
  refresh        = true           # optional: fetch again before it expires
  accepted_types = ["image/png"]  # optional: other answers count as failures
  cache_size     = "20MB"         # optional: most this upstream may take in the cache
  description    = "DWD rain radar frames"   # optional

  [[page]]
  path = "radar.html"
  uses = ["radar"]
  ```

  Some providers answer errors with status `200` and an error document, e.g.
  XML instead of the requested image. With `accepted_types`, such an answer
  is not cached; screens get the stale answer if there is one. The option
  only judges answers, it sends nothing to the provider; requests expecting
  different types (images and their XML metadata) use separate upstreams.
  `cache_size` keeps one busy upstream (e.g. map tiles) from pushing others
  out of the shared cache.

  Only `https` and `GET`, no secrets or extra headers, no redirects, and only
  hosts with public addresses. The host can switch this off or limit it to
  certain hosts; the catalog shows the declared upstreams.

All screens share an upstream's answers, and requests for the same URL
arriving at once lead to one upstream call. Cached answers carry
`X-Deepsplay-Cache` (`hit`, `miss`, or `stale` for an old answer served while
the provider fails) and `Age` in seconds. deepsplay passes the request on
unchanged, so screens share an answer only for the same URL: a page asking
for time-dependent data rounds the time to what the provider offers, e.g. to
5 minutes.

### Shared state

Pages can keep small values on the server, the same on every screen: a
counter, a message one page sets and another shows, the last item seen.

```js
const S = Deepsplay.state
await S.set("shared/message", { text: "Welcome!" })
const message = await S.get("shared/message")        // undefined if not set
const visits = await S.increment("life/visits")      // atomic, from 0
await S.update("shared/names", names => [...(names || []), "Ada"])
```

- State is shared by all pages of the repository and ref, also across
  configurations with different manifests. Name keys by page (`life/...`)
  or as shared (`shared/...`) so pages do not overwrite each other by
  accident. Keys are segments of letters, digits, `.`, `_` and `-`,
  separated by `/`.
- Values are any JSON, at most 64 KB; a repository has room for 1000 keys
  and 5 MB.
- Every write gets a new version. `update` reads, changes and writes only if
  nobody wrote in between, retrying otherwise; `set` takes
  `{ ifVersion }` or `{ onlyNew: true }` for the same check by hand.
  `entry(key)` gives value and version, `list(prefix)` the keys.
- There are no live updates: a page that shows changing state polls, e.g.
  `setInterval(async () => show(await S.get("shared/message")), 10000)`.
- State is neither secret nor protected: anyone on the network can read and
  change it. Pages must cope with any value, and with none.
- Failed requests reject with an error carrying `status` (`412` when someone
  else wrote first, `413` for a value too large, `507` when full).

The same works without the helper over HTTP at `/c/<config>/state/<key>`
(`GET`, `PUT`, `DELETE`, `POST {"increment": n}`, `GET ?prefix=` to list).

### Backends

For logic that upstreams and shared state do not cover, a repository can
bring a backend: a small Python web app that deepsplay installs with `uv`,
runs and keeps running. Pages reach it at `/c/<config>/backend/`.

```toml
[backend]
dir     = "backend"     # with pyproject.toml and uv.lock; not inside pages/
command = ["uvicorn", "app:app", "--host", "127.0.0.1", "--port", "{port}"]
health  = "/health"     # optional: answers 2xx once the app is ready
secrets = ["weather_api"]
```

```js
const config = location.pathname.split("/")[2]
const data = await (await fetch(`/c/${config}/backend/forecast`)).json()
```

- The host must allow it for the configuration (`backend = true`);
  otherwise the block is ignored with a warning on the status page and the
  backend answers `404`. Backends run code from the repository on the
  server, so hosts allow them only for repositories they trust.
- The app listens on `127.0.0.1` at the port it gets (`{port}` in `command`,
  also `PORT`). Its environment holds only `PORT`, `HOME`,
  `DEEPSPLAY_CONFIG`, `DEEPSPLAY_URL` (deepsplay itself, e.g. for shared
  state), `DEEPSPLAY_DATA_DIR` (a directory that persists) and the secrets it
  names and the host allows.
- Dependencies come from `uv.lock` (`uv sync --frozen`); `uv` installs the
  Python version the project asks for. Keep `.venv` out of the repository.
- A new revision is shown only once its backend is ready; if it fails, the
  previous revision and its backend keep running and the status page shows
  why, with the backend's recent output.
- Requests pass `Accept`, `Accept-Language` and `Content-Type`, no cookies;
  answers are limited to 5 MB and 30 seconds. No WebSockets or server-sent
  events for now.
- With a local directory (`path =`), the backend restarts when files in
  `dir` change.

## Trying pages

- **Catalog**: `/catalog/<config>` shows the rotation, every page with its
  parameters and variants, a preview at different screen sizes, and a
  playground to try parameter values.
- **Pinning**: `/c/<config>?page=clock.html` shows one page without rotating.
  A query for the page is encoded: `?page=clock.html%3Fformat%3D12h`.

### Developing locally

In a development setup of deepsplay, a configuration can serve a directory
directly; every save shows at once:

```toml
[[config]]
name = "mine"
path = "/home/me/lobby-screen"
```

Alternatively `repo = "file:///home/me/lobby-screen"` goes through git like
production, showing only committed changes.

## Guidelines

These are recommendations; build what your screens need.

- **Screens**: pages can adapt to any size and aspect ratio (viewport units,
  flexible layouts), or target a known screen. A page that only works in some
  shapes says so in its description. Check different sizes in the catalog
  preview.
- **No interaction**: screens have no pointer or keyboard; pages get no mouse
  input and the pointer is hidden.
- **Timing**: a page starts when it is about to be shown. For its display time,
  declare a `duration` parameter with `from = "duration"`.
- **No external dependencies**: copy fonts, scripts and images into the
  repository instead of loading them from a CDN, so screens keep working
  offline.
- **External data** only through upstreams, never with keys in the page.
- **State**: `localStorage` for state of one display (shared by its pages,
  kept across reloads; use a key prefix per page), `Deepsplay.state` for
  state shared by all screens.
- **Licences**: only fonts and assets that may be redistributed (e.g. SIL
  OFL), with the licence file next to them.
- **Attribution**: data and map providers often require attribution on
  screen (e.g. "© BKG" for TopPlusOpen); the page shows it. Note it in
  `credits` too, so the catalog lists it.
- **Videos**: `muted`, `autoplay` and `playsinline`.
- **Explanations** go into `details`, not into a comment at the top of the
  file, so they appear in the catalog; comments are about the code.

## Several displays from one repository

One repository can serve several configurations:

- **Several manifests** show the same pages in different rotations. A
  configuration names its manifest:

  ```toml
  [[config]]
  name     = "kitchen"
  repo     = "https://github.com/you/screens.git"
  ref      = "main"
  manifest = "rotations/kitchen.toml"
  ```

  Manifests can live anywhere except in `pages/`. Page paths are always
  relative to `pages/`.

- **Separate areas** with `subdir`: each area has its own manifests and
  `pages/`, and configurations on different areas cannot reach each other's
  files.

  ```text
  lobby/screen.toml        lobby/pages/…
  kitchen/screen.toml      kitchen/pages/…
  ```

  ```toml
  [[config]]
  name   = "kitchen"
  repo   = "https://github.com/you/screens.git"
  ref    = "main"
  subdir = "kitchen"
  ```

Configurations on the same repository and ref share one fetch and one cache.
