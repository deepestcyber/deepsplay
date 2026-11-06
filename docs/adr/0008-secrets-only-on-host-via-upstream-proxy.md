# 8. Secrets only on the host, used via an upstream proxy

Date: 2026-11-06

## Status

Accepted

## Context

Pages may call APIs that need credentials, and repositories should be able to
be public. Anything the browser can read is not secret.

## Decision

Secrets stay on the host and are used by the server on a page's behalf.

- Values live in a secrets TOML file outside any repository and the cache (mode
  0600, mounted read-only) or in environment variables.
- The host defines named upstreams: base URL, allowed methods (default `GET`),
  how the secret is added, optional response cache TTL.
- A configuration lists the upstreams it may use. A page names an upstream in
  `screen.toml` and calls `/c/<config>/api/<upstream>/<path>`. A revision asking
  for an upstream its configuration does not allow is rejected.
- The proxy normalizes paths and rejects `..` and absolute URLs, drops cookies
  and the client's `Authorization`, and applies timeouts and a size limit.
- Secret values are never logged, shown on the status page or substituted into
  served files. Git credentials come from the same secrets file.

## Consequences

- Repositories hold no secrets and can be public.
- A repository cannot make the server send a secret to a host of its own.
- The proxy has no login: anyone who reaches the server can call allowed
  upstreams. Upstreams should be read-only and the server stay on the internal
  network.
