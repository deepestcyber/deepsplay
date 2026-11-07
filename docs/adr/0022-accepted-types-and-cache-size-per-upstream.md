# 22. Accepted content types and cache size per upstream

Date: 2026-11-07

## Status

Accepted

Amends [19](0019-upstreams-declared-in-content-repositories.md) and
[20](0020-upstream-cache.md).

## Context

Some providers answer errors with status `200` and an error document, e.g.
GeoServer's WMS sends an XML `ServiceException` instead of the requested
PNG. The upstream cache (ADR 20) caches every `200`, so such an error reaches
all screens for the whole `cache_ttl` and replaces a stale answer that would
have been better.

All upstreams share one cache limited by `upstream_cache_size`, so one busy
upstream (e.g. map tiles) can push out the entries of others.

## Decision

Two optional upstream options, for host upstreams and for upstreams declared
in manifests (added to the allowed fields of ADR 19). Both need `cache_ttl`,
as they only act on cached requests.

`accepted_types`:

- A list of media types without parameters (`"image/png"`), or families
  (`"image/*"`). An answer's `Content-Type` matches with its parameters
  stripped, case-insensitive; an answer without `Content-Type` does not
  match.
- It only judges the answer; nothing is sent to the provider.
- Not set: every `200` is accepted, as before.
- A `200` that does not match counts as a failed fetch, like `429` and `5xx`
  in ADR 20: not cached; a stale answer is served if `stale_ttl` keeps one;
  otherwise the answer is passed on unchanged; recorded as the upstream's
  last error. A scheduled refresh with such an answer counts as a failed
  refresh.
- Requests expecting different types use different upstreams; manifest
  upstreams on the same provider share cache entries by target URL anyway.

`cache_size`:

- A size (e.g. `"20MB"`): the most the upstream's entries may take in the
  cache. When an insert goes beyond it, the upstream's own least recently
  used entries are dropped first; the overall `upstream_cache_size` still
  applies.
- Not set: the upstream shares the whole cache, as before.
- An answer larger than `cache_size` is passed on but not cached.
- A `cache_size` above `upstream_cache_size` is an error in the host
  configuration, and rejects a revision declaring it in its manifest.
- Entries are counted per group as on the status page: host upstreams by
  name, manifest upstreams by URL. Each insert applies the `cache_size` of
  the upstream it came through.

The catalog and the status page show both options with the upstream.

## Consequences

- Error documents sent with `200` no longer spread to all screens when the
  upstream lists its accepted types; detecting errors of the same type (an
  XML exception where XML is expected) stays the page's job.
- Errors drawn into images (e.g. GeoServer's `EXCEPTIONS=...se_inimage`)
  pass as valid; pages should not ask for them.
- One upstream can be kept from crowding out the others; the cache keeps a
  size total per group.
