# 24. Page metadata: author, credits, license

Date: 2026-11-07

## Status

Accepted

Amends [14](0014-page-parameters-defined-in-the-page.md) and
[15](0015-shared-helpers-define-their-parameters.md).

## Context

Pages in a content repository are written by different people, who want to
be named. Many pages show data or assets whose providers require
attribution (e.g. weather radar, map tiles), and pages are copied between
repositories, so their license matters. The catalog should show this, and a
page or its theme may want to show credits on screen. The parameter block
(ADR 14) already holds a page's title and description and is read by the
server (catalog) and by `deepsplay.js` in the browser.

## Decision

The parameter block of a page gets three optional fields; helper definitions
(ADR 15) may have them too.

- `author`: a string, or a list of strings for several people. At most 200
  characters per name; empty names are dropped.
- `credits`: free text attributing data and assets, e.g.
  `"Radar: Deutscher Wetterdienst; map: © BKG (TopPlusOpen)"`. At most 500
  characters.
- `license`: the license of the page itself, preferably an SPDX identifier
  (`"MIT"`, `"CC-BY-4.0"`). At most 100 characters.

All are plain text, trimmed; empty counts as not set. Invalid values are
warnings in the catalog, as for other problems in the block; they never stop
a page from being shown.

- The catalog shows them on the page card and in the preview ("by Ada,
  Grace", credits, license), and on helper cards.
- `deepsplay.js` gets `Deepsplay.page()`, returning the page's metadata from
  its block: `{ title, description, authors, credits, license }`. `authors`
  is always a list (empty without `author`); `credits` and `license` are
  `null` when not set; `title` falls back to the document's `<title>`; a
  page without block gets these defaults.
- Whether and how credits or authors appear on screen is up to the page or
  its theme (e.g. a theme parameter), not deepsplay. Where a provider
  requires on-screen attribution, the page must show it.

## Consequences

- Authors, attributions and licenses are kept where pages are documented,
  next to title and description, and visible in the catalog.
- Themes can show authors and credits without each page repeating them in
  code.
- `Deepsplay.page()` is a new part of the helper's `v1` API; later metadata
  fields can be added to it.
