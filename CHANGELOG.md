# Changelog

All notable changes are listed here. Versions follow `version` in `mix.exs`;
releases are tagged `vX.Y.Z` (see [docs/deployment.md](docs/deployment.md)).

## Unreleased

- The status page shows the app version.
- Manifests can set a default `duration` for all pages; a page's `duration` is
  optional and falls back to the manifest's, or to 15 seconds.

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
