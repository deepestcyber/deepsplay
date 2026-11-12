# 8. Secrets only on the host, used via an upstream proxy

Date: 2026-11-06

## Status

Accepted

Amended by [19](0019-upstreams-declared-in-content-repositories.md):
manifests can declare upstreams without secrets.

Amended by [33](0033-interrupts-over-mqtt.md): the MQTT password comes from
the secrets.

## Context

Pages may call APIs that need credentials, and repositories should be able to
be public. Anything the browser can read is not secret.

## Decision

Secrets stay on the host and are used by the server on a page's behalf.

- Values live in a secrets TOML file outside any repository and the cache
  (`DEEPSPLAY_SECRETS`; mode 0600, mounted read-only; a warning is logged if
  others can read it) or in environment variables `DEEPSPLAY_SECRET_<NAME>`,
  which win over the file. Names are lowercase.
- The host defines named upstreams: base URL, allowed methods (default `GET`),
  how the secret is added, optional response cache TTL and timeout. A secret
  can be added as a header (`header` + `value`) and/or a query parameter
  (`query` + `query_value`); both are templates with `{secret:name}`. A client
  query parameter with the secret's name is dropped.
- References to undefined secrets make the host configuration unusable.
- A configuration lists the upstreams it may use. A page names an upstream in
  `screen.toml` and calls `/c/<config>/api/<upstream>/<path>`. A revision asking
  for an upstream its configuration does not allow is rejected.
- The proxy normalizes paths and rejects `..` and absolute URLs, forwards only
  `Accept`, `Accept-Language` and `Content-Type` (so no cookies and no client
  `Authorization`), returns only safe response headers, and applies timeouts
  and a 5 MB response limit. Failures answer `502` or `504` and are logged on
  the status page.
- Secret values are never logged, shown on the status page or substituted into
  served files.
- Git credentials (`credential` of a configuration) come from the same secrets:
  an HTTPS token (or `username:token`) through a `GIT_ASKPASS` script reading
  environment variables, or an SSH private key in a mode-0600 file through
  `GIT_SSH_COMMAND`. SSH host keys are trusted on first use
  (`StrictHostKeyChecking=accept-new`, `known_hosts` in the cache directory).

## Consequences

- Repositories hold no secrets and can be public.
- A repository cannot make the server send a secret to a host of its own.
- Trusting SSH host keys on first use needs no setup, but the very first
  connection is not verified; a changed key later fails the fetch.
- The proxy has no login: anyone who reaches the server can call allowed
  upstreams. Upstreams should be read-only and the server stay on the internal
  network.
