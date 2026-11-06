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
| 1 | In-page documentation format | open |
| 2 | Shared parameters (theme and other helpers) | open |
| 3 | Default parameters per configuration | open |
| 4 | Page catalog | open |
| 5 | Repository conventions and template | open |

## 1. In-page documentation format

Status: open

Goal: pages document themselves, next to their code: a short description and
their parameters (name, meaning, default, example), optionally variants
(labelled parameter sets) to try. deepsplay reads this for the catalog
(part 4).

Already decided:

- The documentation lives in the HTML file, not in a separate catalog file.

To plan:

- A format deepsplay can read without a full HTML parser at runtime (the one we
  have, `lazy_html`, is a native library and would complicate the Nix and Pi
  builds). Candidates: a dedicated block the browser ignores, e.g.
  `<script type="application/toml" data-deepsplay>…</script>`, found by its
  exact start and end tags; `<meta>` tags; a structured HTML comment like the
  one in `life.html`.
- What is read at all: title (from `<title>`?), description, parameters,
  variants; whether TOML is the format inside, like manifests.
- Where it is read: when a revision is published (cached with the revision) or
  when the catalog is opened.
- How invalid documentation is reported: warnings only, it never rejects a
  revision.

## 2. Shared parameters (theme and other helpers)

Status: open

Goal: parameters provided by shared helpers (in tinker: `theme`, `font`,
`font-ui`, `font-mono`, `duration` from `theme/theme.js`) are documented once,
not in every page.

To plan:

- How a helper documents its parameters (same format as pages, e.g. in the
  helper's own file or a documentation file next to it).
- How a page declares that it uses a helper, so the catalog can list the
  helper's parameters with the page's own.
- Whether deepsplay knows anything about themes, or only about "parameter
  sets" in general.

## 3. Default parameters per configuration

Status: open

Goal: a configuration can set parameters, e.g. `theme = "neon"`, that are
added to the URLs of its pages unless a page sets them itself. One repository
can then look different per screen without changing pages or manifests.

To plan:

- Where defaults are set: in the host configuration per configuration, in the
  manifest, or both; precedence (likely: page query in the manifest, then
  configuration, then manifest defaults).
- Whether defaults also apply to pinned pages (ADR 11) and to an explicit
  `?page=` query.
- Whether a default goes to every page, or only to pages that document the
  parameter (part 1) or use the helper that defines it (part 2).
- Whether deepsplay passes some parameters itself, e.g. `duration` from the
  manifest, so the progress bar no longer needs it repeated in the page path.
- Effect on caching: parameters change page URLs, which is fine for
  revision-keyed URLs.

## 4. Page catalog

Status: open

Goal: a page, linked from `/status`, that lists every configuration with its
pages: the rotation from the manifest (order, duration, weight, query), the
documented pages with description, parameters and variant links, and all other
HTML files in `pages/`. Every entry links to the page pinned
(`/c/<name>?page=…`), variants with their parameters.

To plan:

- One page with a section per configuration, or one page per configuration.
- Previews: links only, or an explicit preview that loads one page at a time
  (live previews of all pages would run every animation and call upstreams).
- How default parameters (part 3) and variants combine in the links.
- How documentation warnings are shown.

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
