# 20. Upstream cache with request coalescing

Date: 2026-11-07

## Status

Accepted

## Context

The upstream proxy (ADR 8, ADR 19) caches successful `GET` answers for an
upstream's `cache_ttl`, so screens share one upstream call. When an entry is
missing or expired, every screen asking at that moment calls the upstream
itself: many screens on one rotation tend to ask at the same time, and
providers with rate limits or costs per call see a burst instead of one call.

## Decision

The upstream cache fetches each answer once, however many screens ask for it.

- Per cache key, at most one upstream request is in flight. Requests for the
  same key arriving while it runs wait for it and get its result, success or
  failure; they do not start requests of their own.
- The cache key is the request as forwarded, never rewritten (ADR 19):
  - host upstreams: upstream name, method, path and query;
  - manifest upstreams: method and full target URL, so configurations and
    repositories declaring the same provider share entries.
- Only successful answers are cached. A failure is passed to the requests
  waiting for it, then forgotten; the next request starts a new fetch.
- Waiting requests are bound by the upstream's timeout, so a hanging provider
  does not hold screens longer than a direct call would.
- Coalescing applies to every cacheable request (`GET` on an upstream with
  `cache_ttl`), for host and manifest upstreams alike.
- Further cache behaviour of phase 3 (serving stale answers, scheduled
  refresh, persistence, status page) extends this ADR before it is built.

## Consequences

- An upstream sees at most one call per cache key and `cache_ttl`, however
  many screens show the page; this is what makes the minimum `cache_ttl` of
  ADR 19 an actual rate limit.
- A slow upstream delays all screens waiting for the same key, not only the
  first.
- The cache needs a process per key or a registry of running fetches, instead
  of a plain table lookup.
