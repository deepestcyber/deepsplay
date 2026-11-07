# Upstream content types and cache size per upstream

Some providers answer errors with status `200` and an error document in the
body. The upstream cache ([ADR 20](../adr/0020-upstream-cache.md)) caches
every `200`, so such an error is served to all screens for the whole
`cache_ttl`, and it replaces a stale answer that would have been better.
This unit adds an upstream option that lists the content types accepted as
successful answers, and an optional cache size per upstream, so one busy
upstream cannot push the entries of others out of the shared cache.

Background: [ADR 8](../adr/0008-secrets-only-on-host-via-upstream-proxy.md)
(upstream proxy), [ADR 19](../adr/0019-upstreams-declared-in-content-repositories.md)
(manifest upstreams), [ADR 20](../adr/0020-upstream-cache.md) (cache),
`Deepsplay.UpstreamProxy.cached_call/6`, `Deepsplay.UpstreamProxy.Cache`.

Status values: `open`, `in progress`, `done`.

| # | Part | Status |
| --- | --- | --- |
| 1 | Decision (new ADR 22, amending ADR 19 and ADR 20) | done |
| 2 | Option `accepted_types` for host and manifest upstreams | done |
| 3 | Option `cache_size` per upstream | done |
| 4 | Docs (`docs/pages.md`, host configuration) | open |

## Motivation: DWD rain radar

The content repository `tinker-display` gets a rain radar page (`radar.html`)
with the DWD WMS (`https://maps.dwd.de/geoserver/dwd/wms`, layer
`dwd:Niederschlagsradar`) over BKG TopPlusOpen map tiles, both as manifest
upstreams.

Observed on 2026-11-07:

- A `GetMap` for a time that does not exist (yet), e.g. a run that is not
  published, answers `200` with `Content-Type: text/xml;charset=UTF-8` and an
  OGC `ServiceException` document (about 500 bytes) instead of a PNG.
  GeoServer does this by default for WMS.
- Valid frames answer `200` with `image/png`.
- The layer's `GetCapabilities` (time dimension and `REFERENCE_TIME`, about
  39 KB) is itself `text/xml`, so the accepted types depend on the request,
  not only on the provider.

The page avoids invalid times by reading the available times from
`GetCapabilities` first, so the error should be rare. It can still happen
(DWD withdrawing or delaying a run, clock-based requests in other pages), and
then the error is cached for all screens until it expires, while a stale PNG
would be the right answer.

The page must not set GeoServer's `EXCEPTIONS` parameter to
`application/vnd.ogc.se_inimage` or `application/vnd.ogc.se_blank`: then the
error comes as a PNG (with the message drawn in, or blank), passes as
`image/png` and is cached. `accepted_types` only helps with the default XML
exceptions.

The map tiles need the attribution required by TopPlusOpen (© BKG) on the
page.

## 1. Decision (new ADR 22)

Status: done (2026-11-07), decided in
[ADR 22](../adr/0022-accepted-types-and-cache-size-per-upstream.md) as
proposed below; ADR 19 and ADR 20 note the amendment in their status
sections (both are built, so they are not edited in place).

Proposal for `accepted_types`:

- New upstream option `accepted_types`: a list of media types, without
  parameters (`"image/png"`, not `"image/png; charset=..."`). Matching is on
  the answer's `Content-Type` with parameters stripped, case-insensitive. A
  trailing `/*` matches a whole family (`"image/*"`). An answer without
  `Content-Type` does not match.
- It only judges the answer; nothing is sent to the provider (it is not the
  request's `Accept` header, which pages set themselves).
- Default: not set, i.e. every `200` is accepted as today.
- With `accepted_types` set, a `200` whose content type does not match is
  treated like a failed fetch (as `429` and `5xx` in ADR 20):
  - not cached;
  - a stale answer is served instead, if `stale_ttl` keeps one;
  - otherwise the answer is passed on unchanged (the page sees the provider's
    error document, as without the cache);
  - counted as the upstream's last error on the status page, e.g.
    `answered 200 text/xml, expected image/png`.
- It needs `cache_ttl` (it only acts on cached requests), like `stale_ttl`
  and `refresh`.
- Allowed for host upstreams and manifest upstreams (added to the allowed
  manifest fields of ADR 19).
- Requests with different accepted types go to different upstreams. For the
  radar, the repository declares two upstreams on the same provider, which is
  already possible since cache keys of manifest upstreams are the target URL:

  ```toml
  [upstream.radar]             # GetMap frames
  url            = "https://maps.dwd.de/geoserver/dwd/wms"
  cache_ttl      = "2h"
  accepted_types = ["image/png"]

  [upstream.radar_times]       # GetCapabilities of the layer
  url            = "https://maps.dwd.de/geoserver/dwd/Niederschlagsradar/wms"
  cache_ttl      = "1m"
  stale_ttl      = "1h"
  refresh        = true
  accepted_types = ["text/xml", "application/vnd.ogc.wms_xml"]
  ```

  (For `radar_times` this does not help against an exception document, which
  is XML too; the page checks the root element. Listing the types still
  guards against HTML error pages from a proxy in front of the provider.)

Proposal for `cache_size`:

- New upstream option `cache_size` (a size like `upstream_cache_size`, e.g.
  `"20MB"`): the most this upstream's entries may take in the cache. When an
  insert goes beyond it, the upstream's own least recently used entries are
  dropped first; the overall `upstream_cache_size` still applies on top.
- Default: not set, i.e. the upstream shares the whole cache as today.
- An answer larger than the upstream's `cache_size` is passed on but not
  cached.
- It needs `cache_ttl`.
- Allowed for host and manifest upstreams. A `cache_size` larger than
  `upstream_cache_size` is an error (host configuration) or rejects the
  revision (manifest), so a repository cannot claim more than the host
  offers.
- Entries are grouped as on the status page: host upstreams by name,
  manifest upstreams by URL. Manifests declaring the same URL with different
  sizes: each insert applies the size of the upstream it came through.

Alternatives considered:

- Detect OGC exceptions specifically (`ServiceExceptionReport` in the body):
  too provider-specific for the proxy.
- Let the page report a bad answer so the cache drops it: needs a new
  endpoint, and a screen could drop good entries for all screens.
- The name `cache_types`: undersells that other types count as failures
  (stale answers, status page), not only that they are not cached.

## 2. Option `accepted_types`

Status: done (2026-11-07)

Built as sketched. `Upstream.cast_accepted_types/1` validates for host and
manifest upstreams (`*/*` is not accepted; leave the option out instead),
`Upstream.accepts?/2` matches. The proxy records a mismatch as
`answered 200 <type>, expected <types>` (`without type` for a missing
`Content-Type`). The status page shows the types under the cache settings,
the catalog as `accepts ...`. A failed refresh keeping the entry is tested
in the cache directly (it applies to any failure, not only a type mismatch).

Sketch:

- Parse and validate in the host configuration (`Upstream` struct) and in
  `Deepsplay.Screen.Upstreams` (manifest): a non-empty list of strings of the
  form `type/subtype` or `type/*`, kept lowercase. `accepted_types` without
  `cache_ttl` is an error.
- In `UpstreamProxy.cached_call/6`, the `fetch` function returns
  `{:cache, ...}` for `200` only if the content type matches; otherwise
  `Stats.failed(group, ...)` and `{:failed, result}`, so the existing stale
  handling applies.
- A scheduled refresh (`refresh = true`) that gets a non-matching type counts
  as a failed refresh: the entry is kept until it expires.
- Catalog and status page show `accepted_types` with the other upstream
  options.
- Tests: matching with and without parameters, wildcard, case, missing
  `Content-Type`; stale answer served on mismatch; mismatch passed on
  without stale entry; refresh with mismatch; host and manifest validation.

## 3. Option `cache_size` per upstream

Status: done (2026-11-07)

Built as sketched. The manifest check gets the host's limit through
`Screen.options/1` (`max_cache_size`). The cache keeps `group_sizes` in its
state, updated on insert, delete (eviction and sweep go through it), load and
clear, and evicts within the group before the overall limit. The catalog
shows `at most 20.0 MB`, the status page `3 entries, 1.2 MB of 20.0 MB`.

Sketch:

- Parse `cache_size` with the existing `:size` type, in the host
  configuration and in `Deepsplay.Screen.Upstreams`; errors for a missing
  `cache_ttl` and for a size above `upstream_cache_size` (the manifest check
  needs the server limit, passed with the configuration's options).
- `UpstreamProxy` passes it to the cache with the other options
  (`ttls.max_size` next to `ttls.group`). `Cache.insert` keeps a size total
  per group, drops the group's least recently used entries while the group
  is above its limit, then applies the overall limit as today. Sizes per
  group are kept in the cache process state, updated on insert, delete,
  eviction, sweep and load.
- The status page shows the limit next to the upstream's entries
  (`12 entries, 3.1 MB of 20 MB`); the catalog shows it with the manifest
  upstream.
- Tests: eviction within a group leaves other groups alone; overall limit
  still applies; an answer above the group limit is not cached; validation
  for host and manifest.

## 4. Docs

Status: open

- `docs/pages.md`, section "External data": both options in the manifest
  example, one sentence on providers that send errors with `200`, one on
  `cache_size`.
- `docs/outline.md` (host configuration example): both options for host
  upstreams.
- ADR 22; status notes in ADR 19 and ADR 20 pointing to it.
- `CHANGELOG.md`.

## Not needed for the radar page

Checked against the expected load, no other change is required:

- Size: a radar frame (1024 x 1024 PNG) is about 40 KB, a map tile about
  67 KB, both far below the 5 MB response limit.
- Cache: per DWD run (every 5 minutes) about 13 new frames (one new
  measurement, 12 forecast frames for one hour ahead), about 0.5 MB; with
  `cache_ttl = "2h"` about 12 MB of radar, plus 10 to 15 MB of tiles per map
  area. Well within the default `upstream_cache_size` of 200 MB; a
  `cache_size` on the tile upstream keeps tiles from crowding out the radar
  frames if more map areas are added. To be checked on the status page once
  running.
- Upstream calls: 13 frame requests per run and one `GetCapabilities` per
  minute, independent of the number of screens.
