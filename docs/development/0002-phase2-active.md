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
| 5 | Repository conventions and template | done |

## 1. In-page documentation format

Status: done (2026-11-07), decided in
[ADR 14](../adr/0014-page-parameters-defined-in-the-page.md); built.

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
  `deepsplay.js`, at `/lib/v1/deepsplay.js` (compatible within `v1`) and at exact
  version paths; pages may ignore it or copy it.
- deepsplay finds the block by text search, without an HTML parser; problems
  are warnings, never rejections.

Built (2026-11-07):

- `assets/lib/deepsplay.js`, bundled by esbuild (profile `deepsplay_lib`)
  into `priv/lib/deepsplay.js` with the vendored TOML parser
  (`assets/vendor/smol-toml`, 1.9.1, BSD-3-Clause) and the version baked in;
  16 KB minified, 7 KB gzipped. `params()`, `params(name)`, `helper()` and
  `api()` are in; the server side of helpers follows in part 2.
- `DeepsplayWeb.LibController`: `/lib/v1/deepsplay.js` (one day, then a week
  `stale-while-revalidate`) and `/lib/deepsplay@X.Y.Z.js` (immutable; the
  current version from the build, released ones from `priv/lib/archive/`).
- `Deepsplay.PageDoc` and `Deepsplay.PageDoc.Param`: finding and parsing the
  block, warnings instead of errors, and the same value rules as the helper.
  Both are tested against `test/support/fixtures/params_cases.json`; the
  JavaScript side runs with Node from the test suite (skipped without Node).
  The shared cases found a bug on the Elixir side (`false` values dropped).
- `life.html` in tinker converted: parameter block with ten parameters and
  four variants, `Deepsplay.params()` instead of hand-written parsing.

Not yet: reading page blocks per revision for the catalog and defaults
(parts 3 and 4).

## 2. Shared parameters (theme and other helpers)

Status: done (2026-11-07), decided in
[ADR 15](../adr/0015-shared-helpers-define-their-parameters.md); built.

Goal: parameters provided by shared helpers (in tinker: `theme`, `font`,
`font-ui`, `font-mono`, `duration` from `theme/theme.js`) are documented once,
not in every page.

Decided:

- A helper registers its definition in its own code:
  ``Deepsplay.helper("<name>", `<TOML>`)`` registers the definition and
  returns the helper's values synchronously. deepsplay finds it by text search
  and indexes all helpers in `pages/` by name per revision.
- Pages name their helpers with `uses = ["theme"]`; the catalog lists helper
  parameters with the page's, marked by helper.
- Load order: `deepsplay.js`, helpers, page code. `Deepsplay.params()` returns
  the page's own parameters, `Deepsplay.params("<name>")` a helper's.
- Collisions are warnings: the page's definition wins over a helper's; of two
  helpers with the same name, the first found counts.
- `enum` values are listed in the definition, also where they mirror files.

Built (2026-11-07):

- `Deepsplay.helper` and `Deepsplay.params("<name>")` in `deepsplay.js`
  (with part 1).
- `Deepsplay.HelperIndex`: `build/1` finds all registrations in `*.js` and
  `*.mjs` below `pages/` (sorted, hidden files and symlinks skipped; the first
  registration of a name counts); `params_for/2` combines a page's parameters
  with its helpers' with origins and collision warnings.
- tinker: `theme.js` registers its seven parameters (`duration` with
  `from = "duration"`); the other pages using the theme (`flame`, `wator`,
  `wireworld`, `font-lab`) load `deepsplay.js` first and declare
  `uses = ["theme"]`; their own parameters are still documented in comments
  only.

## 3. Default parameters per configuration

Status: done (2026-11-07), decided in
[ADR 16](../adr/0016-default-parameters-per-configuration.md); built.

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

Built (2026-11-07):

- `params = {…}` per configuration and `[params]` in manifests; values are
  strings, numbers or booleans, kept as their URL text.
- `Deepsplay.Pages`: page documentation and helper index per revision, cached
  in memory by `pages/` directory and revision key (commit SHA, or the version
  token of a local directory).
- `Deepsplay.PageParams`: per page, the first valid value of configuration,
  manifest and provided values for each declared parameter the page does not
  set itself; invalid values are skipped with a warning; defaults no rotation
  page declares are warned about.
- `Revisions.current/2` carries the added parameters per rotation page and the
  warnings; `ScreenPlan` appends them to page URLs; pinned pages get them
  without a display time; the status page shows the warnings with the
  manifest's.
- In tinker, the theme pages now get `duration` automatically (through the
  theme helper); `?duration=` in paths is only needed for pages without a
  parameter block.

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

Status: done (2026-11-07), decided in
[ADR 18](../adr/0018-content-repository-conventions-and-template.md); not
built yet.

Goal: a recommended layout and set of helpers for content repositories, so new
repositories start well.

Decided:

- A guide for page authors in `docs/pages.md` (layout, page and helper
  documentation, upstreams, the page helper, guidelines, and further down
  several displays from one repository: manifests and `subdir`); the README
  links to it and stays short.
- Layout: manifests at the top, pages in `pages/` as files or folders with an
  `index.html`, repository helpers in `pages/shared/`, assets in
  `pages/assets/` with licence files.
- Guidelines are recommendations: pages can adapt to any size and aspect
  ratio; authors build what their screens need. Further points: no pointer
  input, timing through a `duration` parameter with `from = "duration"`, no
  external dependencies (vendor fonts and scripts), external data only through
  upstreams, per-display state in `localStorage` with a key prefix per page,
  redistributable fonts and assets with licence files, muted autoplaying
  videos.
- One page helper, `deepsplay.js` (renamed from `params.js`; ADR 14):
  parameters, and `Deepsplay.api(upstream, path)` for upstream URLs
  independent of folder depth.
- Template repository `deepestcyber/deepsplay-template`; the shipped
  development configuration shows it, and its pages point to building an own
  repository.

To build: the guide, the template repository, the development configuration
pointing to it, and `Deepsplay.api` in the page helper.

## Changes along the way

- Status page shows the app version (2026-11-07).
- Manifest default `duration` (2026-11-07): a top-level `duration` in a
  manifest applies to pages without their own; a page's `duration` is
  optional; without either, 15 seconds. Built and tested.
