# 5. TOML for host config and screen manifest

Date: 2026-11-06

## Status

Accepted

Amended by [23](0023-reload-host-configuration-on-change.md): the host
configuration is reloaded when it changes.

Amended by [25](0025-time-windows-and-overrides.md): manifest page entries can
have time windows (`when`), manifests `when_empty` and `[[override]]`.

Amended by [28](0028-page-entries-by-glob.md): a page entry can name its
pages with `glob` (and `exclude`) instead of `path`.

Amended by [29](0029-disabled-manifest-entries.md): page entries and overrides
can be switched off with `enabled = false`.

Amended by [33](0033-interrupts-over-mqtt.md): the host configuration can
have an `[mqtt]` section and a configuration an `mqtt_topic`.

Amended by [35](0035-kiosk-mode-switch.md): `kiosk_mode` in `[server]`
switches off hiding the pointer, for development.

## Context

deepsplay reads two kinds of configuration: the host configuration (server
settings, configurations, upstreams) and a manifest in each content repository
that lists the pages to rotate. Both are written by hand and reviewed in git.

## Decision

Both are TOML files.

- Host configuration: one TOML file outside any repository, path set by an
  environment variable. Secrets live in a separate TOML file (see
  [8](0008-secrets-only-on-host-via-upstream-proxy.md)).
- Manifest: a TOML file below the root of the content repository, or of the
  configured `subdir`. Default `screen.toml`; a configuration can name another
  with `manifest`, e.g. `rotations/kitchen.toml`. Manifests must not live in
  `pages/`.
- Page paths in a manifest are relative to `pages/` (see
  [10](0010-url-scheme.md)), so several manifests can list the same pages with
  different rotations. A path may carry a query string that is passed on to
  the page unchanged (`welcome.html?duration=5s`); only the file part is
  checked.
- The manifest is parsed as data with a size limit. Nothing from a repository is
  evaluated as code.

## Consequences

- Both files are readable, commentable and diffable, without the pitfalls of
  YAML.
- We depend on a TOML library, since Elixir has no built-in parser.
- Validation is our job: a manifest is checked before its revision is published
  (see [6](0006-sha-keyed-revision-cache-with-git-cli.md)).
- One repository can serve several configurations: with different manifests
  sharing pages, or with different `subdir`s that cannot reach each other's
  files.
