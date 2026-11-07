# Some adjustments

Status: completed (2026-11-07)

Smaller changes collected while using deepsplay, each too small for a unit of
its own. Parts are added as they come up.

Background: [outline.md](../outline.md) and [adr/](../adr/).

Status values: `open`, `in progress`, `done`.

| # | Part | Status |
| --- | --- | --- |
| 1 | Descriptions for configurations, upstreams, manifests and pages | done |
| 2 | Byte sizes with SI and binary units | done |
| 3 | Reload the host configuration on change | done |
| 4 | Page metadata: author, credits, license | done |
| 5 | Time windows and overrides | done |

## 1. Descriptions for configurations, upstreams, manifests and pages

Status: done (2026-11-07)

Built as decided, with a `:description` type in `Deepsplay.TomlSchema`.
Status page: under the configuration's name and the upstream's URL.
Catalog: an "About" row for the configuration, the manifest's description
under its title, per rotation entry, and on manifest upstream cards.

Goal: an operator or repository author can say in a sentence what something
is for, and the status page and catalog show it.

Decided:

- An optional `description` (free text string) for:
  - configurations (`[[config]]` in the host configuration), e.g. "kiosk at
    the entrance";
  - host upstreams (`[upstream.<name>]` in the host configuration);
  - manifest upstreams (`[upstream.<name>]` in a manifest, ADR 19);
  - manifests (top level, next to `title`), describing the rotation;
  - page entries (`[[page]]` in a manifest), saying why this entry is in
    the rotation, e.g. when one page appears several times with different
    queries ("slow version for the kitchen"). The page's own description
    (ADR 14) still says what the page is.
- Plain text, shown as text (never as HTML), trimmed; empty counts as not
  set. At most 500 characters; a longer one is an error like other invalid
  values.
- Shown on the status page (configurations, upstreams) and in the catalog
  (configuration header, rotation entries, manifest upstreams).
- ADR 19 lists the fields allowed for manifest upstreams; `description` is
  added there with a note in its status section, as for ADR 22.

Not needed elsewhere: pages, helpers and parameters have descriptions in
their parameter blocks already (ADR 14, ADR 15), variants have labels;
secrets are never shown; screens are not configured; a named state
namespace belongs to a configuration; there is one `[server]`.

## 2. Byte sizes with SI and binary units

Status: done (2026-11-07)

Built as decided, in `Deepsplay.ByteSize` (`parse/1` for the `:size` type
of `Deepsplay.TomlSchema`, `format/1` for the status page and catalog).
`TB` and units in other spellings are refused.

Today: sizes (`upstream_cache_size`, `cache_size`) accept `B`, `KB`, `MB`,
`GB`, all counted in powers of 1024, so `"200MB"` is 209,715,200 bytes. The
status page shows sizes in the same 1024-based units labelled `KB` and `MB`.

Goal: units mean what they say.

Decided:

- SI units count in powers of 1000: `kB` (also `KB`), `MB`, `GB`.
- Binary units count in powers of 1024: `KiB`, `MiB`, `GiB`.
- `B` and a plain integer are bytes.
- Decimals are allowed (`"1.5GB"`), rounded down to whole bytes; the result
  must be at least 1 byte.
- Units are matched as written (no `mb` or `Mb`, which reads as megabit);
  spaces between number and unit are allowed.
- The default `upstream_cache_size` becomes `"200MB"` in SI, 200,000,000
  bytes (about 5% less than today's default).
- The status page and catalog show sizes in SI units (`kB`, `MB`, `GB`), so
  they match what operators write.
- Existing host configurations keep working; values written with `MB` or
  `GB` shrink by about 5% (or 7% for `GB`). Noted in the changelog.

Tests: each unit, decimals, spaces, rejected spellings, display.

## 3. Reload the host configuration on change

Status: done (2026-11-07)

Built in `Deepsplay.HostConfig.Watcher` (with `Watcher.SignalHandler` for
`SIGHUP`, added next to the default handler of `erl_signal_server`):

- `Store.read/0` and `Secrets.read/0` read without storing, so nothing
  changes before a new version is known to be valid.
- `Pollers.reconcile/2` compares child specs of the old and new host
  configuration: removed or changed ones stop, new or changed ones start.
  A restarted poller checks at once, which fetches and validates its
  configurations again with the new settings.
- `Cache.set_max_size/1` for a new `upstream_cache_size`.
- Screens subscribe to the watcher's topic; a shell whose
  `Store.lookup/1` result differs (changed, removed or new configuration)
  navigates to its own URL and so mounts again.
- The status page shows when the configuration was loaded, the last
  changes, a rejected version's errors, and directories needing a restart.
- Tests run without the watcher (`watch_host_config`); its tests start their
  own; a test sends `:sighup` to `erl_signal_server` to check the signal
  path. Checked on a running server: an added configuration became
  available within the interval, and a broken edit was rejected (logged and
  on `/status`).

Today: the host configuration and the secrets are read once at start
(`Deepsplay.HostConfig.Store.load/0`, kept in `:persistent_term`). Most code
reads it on every use (`Store.get/0`, `Store.lookup/1`), but some parts take
it once at start: the pollers and local watchers (`Deepsplay.Pollers`), the
upstream cache (directory and size limit), the shared state store
(`state_dir`) and the cache cleanup. A change needs a restart.

Goal: a running server picks up a changed host configuration (and secrets
file) on its own, without restarting and without screens going blank.

Decided in [ADR 23](../adr/0023-reload-host-configuration-on-change.md),
with the defaults proposed:

- **Detecting changes**: the host configuration and secrets files are
  checked every 5 seconds for a changed content hash (polling, no inotify);
  `SIGHUP` triggers a check at once.
- **Invalid changes**: not applied; the last good version keeps running, the
  errors are logged and shown on the status page until a valid version
  arrives. A start with an invalid file behaves as today.
- **Applying a valid change**: the store gets the new version; pollers and
  local watchers are reconciled (new started, unused stopped, unchanged
  untouched); configurations with changed content settings are fetched and
  validated again; their screens reload, screens of a removed configuration
  show the fallback page; a new `upstream_cache_size` applies at once; the
  status page shows when the configuration was loaded and what changed.
- **Restart needed**: a changed `cache_dir` or `state_dir`, shown on the
  status page. Environment variables are read at start only.
- Shared state and cache entries of a removed configuration are kept; the
  existing cleanups handle them.

## 4. Page metadata: author, credits, license

Status: done (2026-11-07)

Built as sketched. The rules are tested in Elixir and in `deepsplay.js`
against the shared `test/support/fixtures/metadata_cases.json`.
`Deepsplay.page()` returns a frozen object; its `title` and `description`
come from the block as they are (only `title` falls back to `<title>`). The
catalog shows "by ...", credits and license on page and helper cards.
Credits on screen in the template and `tinker-display` are left to those
repositories.

Goal: people who write pages are named in the catalog, data and assets are
attributed, a page's license is known, and a page or its theme can show
authors and credits on screen.

Decided in [ADR 24](../adr/0024-page-metadata.md):

- Optional fields in the parameter block of a page (ADR 14) and in helper
  definitions (ADR 15): `author` (a string or a list, at most 200
  characters per name, empty names dropped), `credits` (free text, at most
  500 characters) and `license` (preferably an SPDX identifier, at most 100
  characters). Invalid values are catalog warnings.
- The catalog shows them on page cards, in the preview and on helper cards.
- `Deepsplay.page()` in `deepsplay.js` returns `{ title, description,
  authors, credits, license }` from the block; `authors` is always a list,
  `credits` and `license` are `null` when not set, `title` falls back to the
  document's `<title>`.
- Showing authors or credits on screen is up to the page or its theme, e.g.
  a theme parameter; where a provider requires on-screen attribution, the
  page must show it. For the template and `tinker-display` that is work in
  those repositories.

Sketch:

- `Deepsplay.PageDoc` reads the fields (Elixir); the shared cases in
  `test/support/fixtures/params_cases.json` get metadata cases so Elixir and
  `deepsplay.js` agree.
- `Deepsplay.HelperIndex` keeps a helper's metadata.
- Guide (`docs/pages.md`): the fields in the block example, a guideline on
  required attributions next to "Licences", `Deepsplay.page()` under
  "Reading parameters", a theme example for credits.

## 5. Time windows and overrides

Status: done (2026-11-07)

Built as decided:

- `Deepsplay.TimeWindow` parses and evaluates windows in Elixir;
  `assets/js/schedule.js` evaluates them in the browser, imported by the
  rotation hook (`@/js/schedule`). Both pass the shared
  `test/support/fixtures/time_window_cases.json` (the Node run gets them in
  the form the server sends, via `TimeWindow.to_plan/1`).
- Additions to the format, all following from the rules: date ranges wrap
  over the end of a year or month (`"12-31..01-01"`, `"30..02"`), weekday
  ranges over the week end (`"fri-mon"`); `02-29` matches in leap years.
- The plan carries `when` per page, `overrides` (URL, windows, priority,
  names that get the remaining time) and `empty`. The hook checks at every
  full minute (all boundaries are whole minutes), re-picks among active
  pages at each page change, and shows a black screen by fading out and
  clearing the visible frame; the status page then shows no current page.
- A new plan with changed overrides applies at the next page change, like
  other plan changes.
- The catalog's "active now" uses the server's local time.
- Checked in headless Chromium against a running server: page shown,
  override starting on the minute, interrupted page back when it ended,
  black screen after the last window closed.

Goal: pages can be limited to times (a night page, an event, days of the
month), screens handle a rotation whose active pages change, down to one or
none, and overrides interrupt the rotation for a time (one-time or
recurring events).

Decided in [ADR 25](../adr/0025-time-windows-and-overrides.md):

- `when` on `[[page]]`: one window or a list; a window has optional
  `start`/`end` (continuous period), `dates` (`YYYY-MM-DD`, `MM-DD` yearly,
  `DD` monthly, ranges with `..`, lists), `days` (`mon`-`sun`, ranges,
  lists) and `from`/`until` (daily `HH:MM`, overnight if `until` is before
  `from`). Dates always ISO, times always 24-hour, in the screen's local
  time. Name of the format: time windows.
- Rotation picks among the active pages at each change; a page finishes its
  display time; one active page stays without reloading; none active shows
  `when_empty` (`"black"` by default, or a page path), checked every minute
  and at the next boundary. Pinned pages ignore windows.
- `[[override]]` entries: `path` and `when` required, `priority` (default
  0), `description`, `uses` optional. An active override interrupts at
  once; highest priority wins, the first on equal priority; a lower one
  comes back when a higher one ends. Afterwards the rotation continues with
  the interrupted page, with a fresh display time. Overrides beat
  `when_empty`; `from = "duration"` gets the window's remaining time; pinned
  pages ignore overrides.
- The catalog shows windows and whether an entry is active now, and lists
  the overrides.

Sketch:

- Parse and validate windows in `Deepsplay.Screen` (Elixir); the rotation
  plan sent to screens carries them.
- Evaluate in the shell's rotation code (browser), with the same rules in
  Elixir for the catalog's "active now"; shared test cases (as for
  parameters) keep both in line.
- The shell schedules a timer for the next window boundary of any override
  (and of pages when none is active), computed from the windows.
- Tests: each field, overnight windows, open-ended periods, yearly and
  monthly dates, list of windows; rotation with changing sets, one page, no
  page, `when_empty`, pinned pages; overrides starting mid-page, priorities
  and ties, nested overrides, resuming the interrupted page, remaining-time
  duration.
- Guide (`docs/pages.md`): the format with examples, `when_empty`,
  overrides.

