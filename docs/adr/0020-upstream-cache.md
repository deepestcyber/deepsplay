# 20. Upstream cache: coalescing, stale answers, refresh, persistence

Date: 2026-11-07

## Status

Accepted

## Context

The upstream proxy (ADR 8, ADR 19) caches successful `GET` answers for an
upstream's `cache_ttl`, so screens share one upstream call. When an entry is
missing or expired, every screen asking at that moment calls the upstream
itself: many screens on one rotation tend to ask at the same time, and
providers with rate limits or costs per call see a burst instead of one call.
When a provider fails, screens get an error although a recent answer would
do, and a restart or deploy empties the cache, causing another burst. The
cache also has no size limit.

## Decision

The upstream cache fetches each answer once, however many screens ask for it,
keeps it available when the provider fails, and survives restarts.

Coalescing:

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

Stale answers:

- An upstream option `stale_ttl` (a duration, off by default) keeps an entry
  that long after `cache_ttl` has run out.
- An expired entry is fetched again on the next request (coalesced). If that
  fetch fails (timeout, connection error, `429` or `5xx`), the stale answer is
  served instead of an error. Other `4xx` answers are passed on and never
  replaced by stale data.
- Screens wait for the fetch rather than getting the stale answer first.
- Answers carry `X-Deepsplay-Cache` (`hit`, `miss` or `stale`) and `Age`.

Scheduled refresh:

- An upstream option `refresh = true` makes deepsplay fetch recently requested
  keys again shortly before they expire, with `cache_ttl` as interval, so
  screens get cache hits.
- A key is refreshed while it was requested within the last three times
  `cache_ttl`; after that it is left to expire. There is no list of URLs to
  refresh: pages build their URLs, and URLs no longer requested drop out on
  their own.

Persistence and limits:

- A server setting `upstream_cache_size` (e.g. `"200MB"`) limits the cache,
  memory and disk together; the least recently used entries are dropped
  first.
- Every cached entry is also written to `cache_dir/upstream/`, in the
  background. On start, entries are loaded again: fresh while within
  `cache_ttl`, then stale while within `stale_ttl`, otherwise deleted. Expiry
  on disk uses wall-clock time.

Status page:

- Per upstream: its origin (host configuration, or the manifest of a
  configuration), number and size of entries, hits, misses, stale answers
  served, last fetch and last error. In total: cache size against the limit.

## Consequences

- An upstream sees at most one call per cache key and `cache_ttl`, however
  many screens show the page; this is what makes the minimum `cache_ttl` of
  ADR 19 an actual rate limit.
- With `refresh`, an upstream sees one call per `cache_ttl` for each URL that
  screens use, and none for URLs nobody asks for; a URL that changes (e.g. a
  rounded time) costs at most one extra fetch per change.
- A slow upstream delays all screens waiting for the same key, not only the
  first; `refresh` makes such waits rare.
- With `stale_ttl`, screens can show outdated data while a provider fails;
  pages that care read `X-Deepsplay-Cache` or `Age`.
- Answers of upstreams with secrets are written to disk too; `cache_dir`
  stays on the server like the git checkouts.
- The cache needs a registry of running fetches and refresh timers, and size
  accounting, instead of a plain table lookup.
