# 29. Disabled manifest entries

Date: 2026-11-08

## Status

Accepted

Amends [5](0005-toml-for-host-config-and-screen-manifest.md) and
[25](0025-time-windows-and-overrides.md).

## Context

To take an entry out of the rotation for a while, it has to be deleted or
commented out, or given a time window that never applies. The first two lose
its settings or hide it from the catalog; the last works, but says nothing
about the intent.

## Decision

`[[page]]` (with `path` or `glob`, ADR 28) and `[[override]]` entries get
`enabled`, a boolean, default `true`.

```toml
[[page]]
path    = "winter.html"
enabled = false
```

- A disabled entry is validated like any other (a missing file is still an
  error), but not shown: screens never receive it, and a disabled glob
  entry finds no pages and reports no warnings about matching.
- A disabled entry with `path` still keeps its file out of glob entries, so
  `enabled = false` also takes one page out of a directory.
- The name is `enabled`, not `active`: "active" is the state of a time
  window at a moment (ADR 25), shown as "active now" in the catalog.
- The catalog lists disabled entries below the rotation and the overrides,
  so they stay visible.

## Consequences

- Entries can be switched off and on with one line, keeping their settings.
- Disabled entries still have to be valid, so a page they name cannot be
  removed without also removing or changing the entry.
