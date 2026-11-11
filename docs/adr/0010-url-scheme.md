# 10. URL scheme

Date: 2026-11-06

## Status

Accepted

Amended by [32](0032-interrupts.md): `/c/<name>/interrupts/<name>` triggers
and ends interrupts.

## Context

Screens pick a configuration by URL. Page files must be cacheable, and a screen
still on an older revision must be able to finish loading it.

## Decision

| Path | Purpose |
| --- | --- |
| `/` | Shell for the default configuration |
| `/c/<name>` | Shell for a named configuration |
| `/c/<name>/r/<sha>/<path>` | File from `pages/` of a revision |
| `/c/<name>/api/<upstream>/<path>` | Upstream proxy (see [8](0008-secrets-only-on-host-via-upstream-proxy.md)) |
| `/c/<name>/state/<key>` | Shared state for pages (see [21](0021-shared-state-for-pages.md)) |
| `/c/<name>/backend/*` | Reserved for sidecars, unused in phase 1 |
| `/status` | Status page |
| `/catalog`, `/catalog/<name>` | Page catalog (see [17](0017-page-catalog.md)) |
| `/lib/v1/deepsplay.js`, `/lib/deepsplay@X.Y.Z.js` | The page helper `deepsplay.js` (see [14](0014-page-parameters-defined-in-the-page.md)) |

- A URL can only select a configuration the host defined, never name an
  arbitrary repository. An unknown name shows the fallback page.
- Only files in `pages/` below the configuration's root (the repository, or its
  `subdir`) are delivered; `<path>` is relative to `pages/`. Manifests,
  `.gitignore`, READMEs and any other directory are never delivered. Hidden
  files and directories (names starting with `.`) inside `pages/` are not
  delivered either.
- Files under `/r/<sha>/` never change and are served with long cache lifetimes,
  `X-Content-Type-Options: nosniff` and the type derived from the extension.

## Consequences

- Kiosk start URLs are short and stable.
- Old and new revisions can be served side by side during a switch.
- Repositories can hold files that are never delivered, in any directory other
  than `pages/`, which leaves room for future features.
- All pages share the server's origin, so one page can call another
  configuration's proxy paths. Acceptable for trusted repositories; untrusted
  ones would need separate origins or sandboxed iframes.
