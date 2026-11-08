# 28. Page entries by glob

Date: 2026-11-08

## Status

Accepted

Amends [5](0005-toml-for-host-config-and-screen-manifest.md).

## Context

Each page in the rotation needs its own `[[page]]` entry in the manifest. A
repository with many small pages that share the same settings (duration,
time window) repeats the same entry for every one of them, and a new page is
only shown once someone adds its entry.

## Decision

A `[[page]]` entry can name its pages with a pattern instead of a path:

```toml
[[page]]
glob     = "small/*.html"
exclude  = ["small/draft-*.html", "small/old.html"]   # optional
query    = "theme=neon"                               # optional
duration = "20s"
when     = { from = "08:00", until = "20:00" }
```

Each matching page becomes an entry of its own, as if it had been written
with `path` and the entry's other fields.

- An entry has either `path` or `glob`, not both. `exclude` and `query` are
  allowed only with `glob`; with `path`, the query stays part of the path.
- Patterns are relative to `pages/`: `*` and `?` match within one path
  segment, `**` across directories, `{a,b}` alternatives. Patterns must not
  leave `pages/` (no absolute paths, no `..`). Only `.html` files match.
- `exclude` is a pattern or a list of patterns, in the same form; matching
  files are left out.
- Also left out: files marked `page = false` (ADR 14), and files that have an
  entry with `path` anywhere in the manifest, so a single page can get its
  own settings without appearing twice. A file matched by several `glob`
  entries appears once for each.
- The pages found are inserted where the entry stands, in alphabetical order
  of their paths.
- `weight`, `duration`, `when` and `description` apply to each page found;
  in a random rotation each page has the full `weight`.
- Pages are found again for every revision: a new file that matches is in
  the rotation with the next revision, without changing the manifest.
- Warnings in the catalog, without stopping the revision: `path` and `glob`
  in the same entry, `exclude` or `query` without `glob`, a pattern leaving
  `pages/`, a `glob` that matches no page, an `exclude` pattern that matches
  nothing the `glob` found.
- The expansion happens on the server when the revision is loaded; screens
  receive individual entries, so the rotation in the browser is unchanged.
- The catalog's rotation shows each page found, marked with its pattern.
- Overrides (ADR 25) keep `path` only: an override shows one page.

## Consequences

- A directory of small pages needs one manifest entry; adding a page is
  adding a file.
- Which pages are in the rotation is no longer visible in the manifest
  alone; the catalog shows the result.
- Many pages found by one entry take a large share of a random rotation,
  each with the full weight; a smaller `weight` balances that.
