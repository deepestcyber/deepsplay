# 14. Page parameters defined in the page

Date: 2026-11-07

## Status

Accepted

Amended by [24](0024-page-metadata.md): optional `author`, `credits` and
`license`.

## Context

Pages take parameters from their URL (e.g. `?cells=90&gps=10`). Their
description and defaults should be written once, next to the code, and serve
both the page's own parameter parsing and deepsplay's documentation (the page
catalog, defaults per configuration). deepsplay must read them without a full
HTML parser.

## Decision

A page defines its parameters in a TOML block in its HTML file:

```html
<script type="application/toml" id="deepsplay-page">
description = "Conway's Game of Life over the whole screen."
uses = ["theme"]

[params.cells]
type        = "int"
default     = 90
min         = 4
description = "Cells along the shorter side of the screen."

[[variants]]
label = "Large cells, slow"
query = "cells=40&gps=4"
</script>
<script src="/lib/v1/deepsplay.js"></script>
```

- The block is a `<script>` with type `application/toml` and id
  `deepsplay-page`; the browser does not execute it. deepsplay finds it by its
  exact start tag and the next `</script>`, so the block must not contain
  `</script`. TOML 1.0, as in manifests.
- Fields: `title` (default: the page's `<title>`), `description`, `uses`
  (shared helpers whose parameters apply), `page`, `[params.<name>]` and
  `[[variants]]`. All are optional.
- `page = false` marks an HTML file in `pages/` as not a page, e.g. a fragment
  other pages load. It is still delivered, but not offered as a page (no pin
  link, preview or playground in the catalog), and a manifest rotating it gets
  a warning. HTML files without a block are pages.
- A parameter has `type` (`string`, `int`, `number`, `bool`, `duration` as in
  manifests, `color`, `enum` with `values`), optionally `default`, `min`,
  `max` and `description`.
- A variant is a labelled example query (`label`, `query`). deepsplay uses
  variants only in the catalog, as pinned links.
- deepsplay serves one page helper, `deepsplay.js`, with all functions it
  offers pages, under a global `Deepsplay`:
  - `Deepsplay.params()` reads the page's block and the URL and returns the
    page's own parameters, typed, with defaults applied and limits enforced
    (it bundles its TOML parser); `Deepsplay.helper` and
    `Deepsplay.params("<helper>")` serve shared helpers (ADR 15);
  - `Deepsplay.api(upstream, path)` returns the URL of an upstream of the
    page's configuration (ADR 8), independent of how deep the page lies in
    `pages/`.
- Paths of the helper:
  - `/lib/v1/deepsplay.js`: compatible within `v1`; cached for a day, then up
    to a week with `stale-while-revalidate`. An incompatible change becomes
    `v2`; `v1` stays served.
  - `/lib/deepsplay@X.Y.Z.js`: one exact version, cached immutably; old
    versions stay served.
- deepsplay reads the same block on the server (catalog, defaults per
  configuration). Problems in it are warnings, never a reason to reject a
  revision.
- Pages may ignore the helper, or copy it into their repository.

## Consequences

- Description, type, default and limits are written once and are always the
  same in the page and in the documentation.
- Page code gets shorter: no hand-written parameter parsing.
- deepsplay knows which parameters a page accepts, which defaults per
  configuration and checks of manifest queries can build on.
- A page using `/lib/v1/deepsplay.js` works only when served by deepsplay; in
  development that means local directory mode (ADR 12).
- `/lib/` becomes a reserved path (ADR 10).
- Two TOML parsers (JavaScript and Elixir) read the same block; the blocks
  stay within plain TOML 1.0 features to avoid differences.
