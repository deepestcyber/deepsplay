# 19. Upstreams declared in content repositories

Date: 2026-11-07

## Status

Accepted

Amends [8](0008-secrets-only-on-host-via-upstream-proxy.md).

Amended by [22](0022-accepted-types-and-cache-size-per-upstream.md):
`accepted_types` and `cache_size` are allowed in manifests.

## Context

Pages often use open APIs that need no key, such as weather or rain radar
data. Calling them from the browser works, but then every screen calls the
provider itself; with many screens that is wasteful and can hit rate limits.
The upstream proxy (ADR 8) caches for all screens, but only for upstreams the
host defines, so every open API needs a change of the host configuration.
Proxying arbitrary URLs is not an option: deepsplay runs inside the internal
network and would become an open proxy into it.

## Decision

A manifest can declare upstreams without secrets; they use the same proxy and
cache as host upstreams.

- Declared in the manifest, like host upstreams but restricted:

  ```toml
  [upstream.radar]
  url       = "https://maps.dwd.de/geoserver/dwd/wms"
  cache_ttl = "5m"
  ```

  Allowed: `url`, `cache_ttl`, `timeout` and the cache options planned in
  phase 3 (e.g. stale serving, scheduled refresh). Not allowed: secrets,
  headers, query templates, methods other than `GET`.
- Pages call them as any upstream: listed in the page's `uses`, called with
  `Deepsplay.api("radar", ...)` at `/c/<config>/api/radar/...`.
- A manifest upstream with the name of an upstream the configuration allows
  from the host configuration is an error; the revision is rejected.
- Guards, beyond those of ADR 8:
  - `https` only.
  - The target address is checked when connecting, after DNS resolution:
    the host name is resolved to all its IPv4 and IPv6 addresses, and the
    request is refused if any of them is loopback, private, link-local,
    unique-local or otherwise non-public. deepsplay then connects to a
    checked address, passing the host name for TLS verification, SNI and the
    `Host` header, so neither the URL nor DNS can reach the internal network.
    Any port is allowed. Redirects are not followed.
  - `cache_ttl` is required, with a minimum of one minute, so the proxy never
    passes every screen request through.
  - Response size limit as in ADR 8 (5 MB), applied to text and binary
    bodies (images) alike.
- The host decides whether repositories may declare upstreams, with server
  settings that a configuration can override by fields of the same name:
  - `repo_upstreams = true | false`, default `true`;
  - `repo_upstream_hosts = ["*.dwd.de"]`, default empty (any public host).
    `dwd.de` matches that name only, `*.dwd.de` its subdomains but not
    `dwd.de` itself.

  A revision declaring upstreams where this is not allowed, or with a URL
  outside the allowed hosts, is rejected.
- The status page shows manifest upstreams with their origin (ADR 20); the
  catalog shows them with URL, `cache_ttl` and the pages using them.

## Consequences

- Pages can use open APIs with a shared cache without touching the host
  configuration.
- Whoever can push to a content repository can make deepsplay send `GET`
  requests to public hosts of their choice, at most once per minute per URL
  and with no secrets attached (with request coalescing,
  [ADR 20](0020-upstream-cache.md)). Hosts that do not want this switch it
  off or restrict it to known domains.
- Checking addresses means resolving names in deepsplay and connecting to an
  address with an explicit host name (Mint's `hostname` option through Req),
  with one connection pool per declared host.
- The proxy forwards path and query unchanged and caches by them; it never
  rewrites a request. Screens share a cache entry only for the same URL, so
  pages build stable URLs themselves (e.g. round time parameters to the
  provider's interval), as only the page knows what its data needs.
