# Changelog

All notable changes are listed here. Versions follow `version` in `mix.exs`;
releases are tagged `vX.Y.Z` (see [docs/deployment.md](docs/deployment.md)).

## Unreleased

- The status page shows the app version.
- Manifests can set a default `duration` for all pages; a page's `duration` is
  optional and falls back to the manifest's, or to 15 seconds.
- Page helper `deepsplay.js` at `/lib/v1/deepsplay.js`: pages define their
  parameters in a TOML block and read them typed, with defaults and limits;
  `Deepsplay.api()` builds upstream URLs (ADR 14).
- Shared helpers register their parameters with `Deepsplay.helper()`
  (ADR 15).
- Default parameters per configuration (`params = {…}`) and per manifest
  (`[params]`), and the display time for parameters with `from = "duration"`,
  are added to the URLs of pages that declare them (ADR 16).
- Page catalog at `/catalog`: per configuration the rotation, all pages with
  their documentation and parameters, helpers and warnings; preview at
  different screen sizes and a playground for parameters (ADR 17).

## 0.1.0 – 2026-11-07

First version (phase 1, see [docs/development](docs/development/)).

- Screens show pages from git repositories, rotating them sequentially or
  weighted at random; a single page can be pinned with `?page=`.
- Host configuration in TOML with named configurations; manifests in the
  content repositories; only `pages/` is delivered.
- Revision cache keyed by commit SHA, kept across restarts; new commits are
  picked up by polling and reach running screens live.
- Status page with configurations, connected screens and recent errors.
- Upstream proxy with host-side secrets and a response cache; credentials for
  private repositories.
- Local directories served live in development.
- Container image for amd64 and arm64, built by GitHub Actions.
