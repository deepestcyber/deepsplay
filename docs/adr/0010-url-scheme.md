# 10. URL scheme

Date: 2026-11-06

## Status

Accepted

## Context

Screens pick a configuration by URL. Page files must be cacheable, and a screen
still on an older revision must be able to finish loading it.

## Decision

| Path | Purpose |
| --- | --- |
| `/` | Shell for the default configuration |
| `/c/<name>` | Shell for a named configuration |
| `/c/<name>/r/<sha>/<path>` | File from a revision |
| `/c/<name>/api/<upstream>/<path>` | Upstream proxy (see [8](0008-secrets-only-on-host-via-upstream-proxy.md)) |
| `/c/<name>/backend/*` | Reserved for sidecars, unused in phase 1 |
| `/status` | Status page |

- A URL can only select a configuration the host defined, never name an
  arbitrary repository. An unknown name shows the fallback page.
- Files under `/r/<sha>/` never change and are served with long cache lifetimes,
  `X-Content-Type-Options: nosniff` and the type derived from the extension.

## Consequences

- Kiosk start URLs are short and stable.
- Old and new revisions can be served side by side during a switch.
- All pages share the server's origin, so one page can call another
  configuration's proxy paths. Acceptable for trusted repositories; untrusted
  ones would need separate origins or sandboxed iframes.
