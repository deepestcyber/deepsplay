# 18. Content repository conventions and template

Date: 2026-11-07

## Status

Accepted

## Context

Content repositories are written by people who do not work on deepsplay
itself. They need a recommended structure, guidelines for pages and a working
starting point. A fresh development setup of deepsplay should show something
right away.

## Decision

- deepsplay documents how to build content repositories in a guide,
  `docs/pages.md`: recommended layout, how to document pages and helpers
  (ADR 14, ADR 15), using upstreams and the page helper, and guidelines for
  pages. Further down, as an advanced topic, it explains serving several
  displays from one repository: several manifests sharing pages, and
  separate areas with `subdir` (ADR 5). The guide holds the details; ADRs
  only hold the decisions. The README stays short and links to it.
- Recommended layout, below the root: manifests at the top (`screen.toml`,
  further ones e.g. in `rotations/`), pages in `pages/` as single files or as
  folders with an `index.html`, the repository's own helpers in
  `pages/shared/`, shared assets in `pages/assets/` with their licence files.
- Guidelines are recommendations, not limits: pages can adapt to any screen
  size and aspect ratio, and authors build what their screens need.
- A public template repository, `deepestcyber/deepsplay-template`, to be used
  with GitHub's "Use this template": a manifest, documented example pages with
  parameters and a variant, a small theme helper, a fragment with
  `page = false`, and a README pointing to the guide. Its pages say that they
  are an example and that real content belongs in an own repository added to
  the host configuration.
- The shipped development configuration (`config/deepsplay.dev.toml`) shows
  the template repository, so a fresh setup displays something at once.

## Consequences

- New content repositories start from a working, documented example.
- The guide can change with practice without new ADRs.
- A fresh development setup needs network access to fetch the template.
- The template must be kept working with each change of the page helper or
  the manifest format.
