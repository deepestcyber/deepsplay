# Phase 2: page repository design

Phase 2 designs how content repositories are built and documented, and what
deepsplay offers on top: in-page documentation, a catalog of all pages, and
default parameters per configuration. It starts with planning; each part ends
with a decision (usually an ADR) before anything is built.

Reference repository: `tinker-display` (pages with a shared theme in
`pages/theme/`, parameters such as `theme`, `font` and `duration` read by
`theme/theme.js`; `life.html` documents its parameters in an HTML comment).
Background: [outline.md](../outline.md), [adr/](../adr/), in particular ADR 5
(manifests), ADR 10 (only `pages/` is delivered) and ADR 11 (pinned pages).

Status values: `open`, `in progress`, `done`.

| # | Part | Status |
| --- | --- | --- |
| 1 | In-page documentation format | done |
| 2 | Shared parameters (theme and other helpers) | done |
| 3 | Default parameters per configuration | done |
| 4 | Page catalog | done |
| 5 | Repository conventions and template | open |

## 1. In-page documentation format

Status: done (2026-11-07), decided in
[ADR 14](../adr/0014-page-parameters-defined-in-the-page.md); not built yet.

Goal: pages document themselves, next to their code: a short description and
their parameters, optionally variants to try. deepsplay reads this for the
catalog (part 4).

Decided:

- Pages define their parameters in a TOML block,
  `<script type="application/toml" id="deepsplay-page">`: `title`,
  `description`, `uses`, `page` (`false` marks a file as not a page),
  `[params.<name>]` (`type`, `default`, `min`, `max`, `values`,
  `description`) and `[[variants]]` (`label`, `query`).
- The same definition drives the page's parameter parsing and the
  documentation, so defaults are written once. deepsplay serves the helper,
  `params.js`, at `/lib/v1/params.js` (compatible within `v1`) and at exact
  version paths; pages may ignore it or copy it.
- deepsplay finds the block by text search, without an HTML parser; problems
  are warnings, never rejections.

To build (with part 4 or as its own step): `params.js` with a bundled TOML
parser and its tests, serving `/lib/` with the caching from ADR 14, the
server-side reader, and converting `life.html` in tinker as the first example.

## 2. Shared parameters (theme and other helpers)

Status: done (2026-11-07), decided in
[ADR 15](../adr/0015-shared-helpers-define-their-parameters.md); not built yet.

Goal: parameters provided by shared helpers (in tinker: `theme`, `font`,
`font-ui`, `font-mono`, `duration` from `theme/theme.js`) are documented once,
not in every page.

Decided:

- A helper registers its definition in its own code:
  ``Params.define("<name>", `<TOML>`)`` returns its values synchronously and
  remembers the definition. deepsplay finds it by text search and indexes all
  helpers in `pages/` by name per revision.
- Pages name their helpers with `uses = ["theme"]`; the catalog lists helper
  parameters with the page's, marked by helper.
- Load order: `params.js`, helpers, page code. `Params.read()` returns the
  page's own parameters, `Params.get("<name>")` a helper's.
- Collisions are warnings: the page's definition wins over a helper's; of two
  helpers with the same name, the first found counts.
- `enum` values are listed in the definition, also where they mirror files.

To build (with part 1): `Params.define` and `Params.get` in `params.js`, the
helper index on the server, and converting `theme.js` in tinker.

## 3. Default parameters per configuration

Status: done (2026-11-07), decided in
[ADR 16](../adr/0016-default-parameters-per-configuration.md); not built yet.

Goal: a configuration can set parameters, e.g. `theme = "neon"`, that are
added to the URLs of its pages unless a page sets them itself.

Decided:

- Levels: configuration `params = {…}` in the host configuration, manifest
  `[params]`, and values deepsplay provides through `from` in a parameter
  definition (`from = "duration"`: the page's display time).
- Precedence: page query (manifest path or pinned link), configuration,
  manifest, provided values, the definition's `default` (in the browser only).
- Parameters go only to pages that declare them, themselves or through `uses`.
  Pinned pages get them too (provided values where they exist).
- Values are checked against the definition; invalid values and undeclared
  defaults are warnings on the status page.

To build (after parts 1 and 2): `params` in the host configuration and
`[params]` in manifests, merging in `ScreenPlan` with the page definitions and
helper index per revision, warnings on the status page, and removing the
repeated `?duration=` from tinker's manifest.

## 4. Page catalog

Status: done (2026-11-07), decided in [ADR 17](../adr/0017-page-catalog.md);
not built yet.

Goal: a page, linked from `/status`, that shows what each configuration shows,
what each page does and accepts, and lets you try pages in different settings.

Decided:

- `/catalog` (all configurations) and `/catalog/<name>` (one configuration:
  header with effective defaults, rotation with merged parameters and their
  origin, all pages with parameter tables and variants, helpers, warnings),
  updating live.
- Pin links in a new tab with merged parameters; a variant's query counts as
  the page query.
- Preview on demand, one at a time, at a real screen size scaled down, with an
  aspect selector (16:9, 9:16, 4:3).
- Playground per page: a form from the parameter definitions that updates the
  preview and produces the pinned link.
- Files marked `page = false` (ADR 14) are listed under "Other files", without
  pin link, preview or playground.

To build (after parts 1 to 3): the two LiveViews, the shared per-revision
reading of page definitions and helpers (also used by part 3), preview and
playground, links from `/status`.

## 5. Repository conventions and template

Status: open

Goal: a recommended layout and set of helpers for content repositories, so new
repositories start well.

To plan:

- Recommended structure below `pages/` (shared helpers, themes, fonts,
  assets) and where manifests go.
- Whether to publish a template repository (tinker as a starting point),
  including a documented example page and the theme helper.
- Guidelines for pages: screen sizes and aspect ratios, no pointer input,
  starting animations on load, reading parameters, licences of fonts and
  assets.
- State per display: pages use the browser's `localStorage` (shared by a
  screen's pages, kept across reloads with a persistent kiosk profile); a key
  prefix per page avoids collisions. Shared state across screens is planned in
  phase 3.
