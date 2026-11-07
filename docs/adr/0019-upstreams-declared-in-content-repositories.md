# 19. Upstreams declared in content repositories

Date: 2026-11-07

## Status

Accepted

Amends [8](0008-secrets-only-on-host-via-upstream-proxy.md).

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
    loopback, private, link-local, unique-local and other non-public
    addresses are refused, so neither the URL nor DNS can reach the internal
    network. Redirects are not followed.
  - `cache_ttl` is required, with a minimum of one minute, so the proxy never
    passes every screen request through.
  - Response size limit as in ADR 8 (5 MB), applied to text and binary
    bodies (images) alike.
- The host decides whether repositories may declare upstreams: a server
  setting with a per-configuration override, allowed by default, optionally
  restricted to a list of host name patterns (e.g. `*.dwd.de`). A revision
  declaring upstreams where this is not allowed is rejected. Final field
  names are chosen when building.
- The status page and the catalog show manifest upstreams with their origin.

## Consequences

- Pages can use open APIs with a shared cache without touching the host
  configuration.
- Whoever can push to a content repository can make deepsplay send `GET`
  requests to public hosts of their choice, at most once per minute per URL
  and with no secrets attached (with request coalescing,
  [ADR 20](0020-upstream-cache-with-request-coalescing.md)). Hosts that do
  not want this switch it off or restrict it to known domains.
- Checking addresses at connect time needs a connection setup of our own
  instead of the HTTP client's default resolution.
- The proxy forwards path and query unchanged and caches by them; it never
  rewrites a request. Screens share a cache entry only for the same URL, so
  pages build stable URLs themselves (e.g. round time parameters to the
  provider's interval), as only the page knows what its data needs.
