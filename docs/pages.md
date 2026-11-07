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
title    = "Lobby"
rotation = "sequential"        # or "random"
duration = "20s"               # display time of pages without their own; default 15s

[params]                       # default parameters for pages that declare them
theme = "dark"

[[page]]
path = "welcome.html"

[[page]]
path     = "life/index.html?cells=40"   # a query is passed on to the page
duration = "45s"
weight   = 2.0                 # random rotation only: shown more often
```

- `rotation = "random"` picks the next page weighted by `weight` (default 1.0)
  and never shows the same page twice in a row.
- Durations are whole numbers with `ms`, `s`, `m` or `h`.
- A page that calls an upstream (see below) lists it: `uses = ["weather"]`.

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

### External data

Pages never contain API keys. The host defines upstreams with their secrets,
and pages call them through deepsplay:

```js
const url = Deepsplay.api("weather", "/current?city=berlin")
const data = await (await fetch(url)).json()
```

`Deepsplay.api` builds the right URL for the page's configuration, however
deep the page lies in `pages/`. The upstream must be allowed for the
configuration and listed in the page's `uses` in the manifest.

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
- **State per display**: `localStorage` works across a screen's pages and
  reloads; use a key prefix per page.
- **Licences**: only fonts and assets that may be redistributed (e.g. SIL
  OFL), with the licence file next to them.
- **Videos**: `muted`, `autoplay` and `playsinline`.

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
