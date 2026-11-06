# 13. Container image built by GitHub Actions

Date: 2026-11-06

## Status

Accepted

## Context

deepsplay is deployed on a NixOS server and, as a local server, on a
Raspberry Pi 5. The repository is public on GitHub. Building on each machine
would need an Elixir toolchain or Nix packaging there; screens reach the server
over plain HTTP on the internal network, by IP or host name.

## Decision

deepsplay is released as a container image, built by GitHub Actions and
published publicly on the GitHub Container Registry
(`ghcr.io/deepestcyber/deepsplay`).

- Every push and pull request runs the tests. Pushes to `main` publish `edge`;
  version tags `vX.Y.Z` publish the version and `latest`.
- Images are built natively for `linux/amd64` and `linux/arm64` on GitHub's
  runners and combined into one multi-architecture image (no emulation).
- The image (multi-stage `Dockerfile`) contains the release, `git` and
  `openssh-client`, and runs as an unprivileged user. The host configuration and
  secrets are mounted read-only; the cache is a volume.
- Machines run it with Docker Compose, or on NixOS with
  `virtualisation.oci-containers`.
- deepsplay serves plain HTTP, without `force_ssl`; HTTPS needs a reverse proxy
  in front. The LiveView origin check accepts the request's own host by
  default, and can be narrowed with `DEEPSPLAY_ORIGINS`.
- Versions follow `mix.exs`, with a `CHANGELOG.md`.

## Consequences

- Machines need only a container runtime; no Elixir, Erlang or build tools.
- Both deployment targets use the same image and the same configuration.
- Updating means pulling a new tag; rolling back means using the previous one.
- On NixOS, the container sits next to the declarative configuration rather
  than being a Nix package.
- Releases depend on GitHub Actions and the registry being available.
