# 17. Page catalog

Date: 2026-11-07

## Status

Accepted

## Context

Repositories will hold many pages, documented in the page itself (ADR 14) and
through shared helpers (ADR 15), with parameters merged per configuration
(ADR 16). There needs to be a place to see what a configuration shows, what
each page does and accepts, and to try pages in different settings. Some HTML
files in `pages/` are not pages to be shown on their own, but fragments other
pages load.

## Decision

deepsplay has a page catalog, without login like the status page, updating
live (new revisions, and every change of a local directory).

- `/catalog` lists all configurations: source, current revision, number of
  pages, warnings. `/status` links to it and, per configuration, to its
  catalog page.
- `/catalog/<name>` shows one configuration:
  - header: source, revision, manifest, rotation strategy, effective default
    parameters with their origin;
  - rotation: the manifest's pages in order with duration, weight and the final
    URL parameters, each marked with its origin (page query, configuration,
    manifest, provided);
  - pages: all HTML files in `pages/`, documented ones first, with title,
    description, helpers used, a parameter table (name, type, default, limits
    or values, description, page or helper, value in this configuration) and
    variants; undocumented files with a pin link only;
  - helpers: every registered helper with its file, parameters and the pages
    using it;
  - warnings: all documentation problems in one list, and next to their page.
- Pages and variants link to the pinned page (ADR 11) in a new tab, with the
  parameters merged as in ADR 16; a variant's query counts as the page query.
- Preview: on demand, one at a time (opening one closes the other). The page
  is rendered in a frame at a real screen size and scaled down to fit. A size
  selector offers a few presets (landscape and portrait full HD, a square, a
  phone) and "custom", which only then shows width and height fields; the
  default is 1920×1080. Pages are not limited to any size or aspect ratio.
- Playground: per page, a form built from its parameter definitions (a select
  for `enum`, number fields with limits, a colour picker for `color`, a select
  with "default / on / off" for `bool`, a text field for `duration` and
  `string`). Fields left empty keep the page's default. It updates the preview
  as values change and produces the pinned link to copy.
- Files marked `page = false` (ADR 14) are listed under "Other files" with
  their description, without pin link, preview or playground.

## Consequences

- Each configuration's content is visible and testable without editing
  manifests or building URLs by hand.
- Previews and the playground run one page at a time, so they do not start
  many animations or upstream calls at once.
- The catalog needs the page definitions, the helper index and the merged
  parameters per revision, which the plan building of ADR 16 needs as well.
- Like the status page, the catalog is open to anyone on the internal network.
