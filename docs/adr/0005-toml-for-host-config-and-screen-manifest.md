# 5. TOML for host config and screen manifest

Date: 2026-11-06

## Status

Accepted

## Context

deepsplay reads two kinds of configuration: the host configuration (server
settings, configurations, upstreams) and a manifest in each content repository
that lists the pages to rotate. Both are written by hand and reviewed in git.

## Decision

Both are TOML files.

- Host configuration: one TOML file outside any repository, path set by an
  environment variable. Secrets live in a separate TOML file (see
  [8](0008-secrets-only-on-host-via-upstream-proxy.md)).
- Manifest: `screen.toml` at the root of the content repository, or of the
  configured subdirectory.
- The manifest is parsed as data with a size limit. Nothing from a repository is
  evaluated as code.

## Consequences

- Both files are readable, commentable and diffable, without the pitfalls of
  YAML.
- We depend on a TOML library, since Elixir has no built-in parser.
- Validation is our job: a manifest is checked before its revision is published
  (see [6](0006-sha-keyed-revision-cache-with-git-cli.md)).
