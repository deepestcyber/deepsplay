# 37. Random rotation without recent repeats

Date: 2026-11-13

## Status

Accepted

Amends [5](0005-toml-for-host-config-and-screen-manifest.md) and
[9](0009-rotation-in-the-browser.md).

## Context

Random rotation never picks the entry currently shown when there is more
than one (ADR 9). With a few entries, the same one still comes back after a
single other: A, B, A, B, A. A rotation of ten pages should get through more
of them before one repeats.

The same file can be in a rotation several times with different parameters
(`life/index.html?cells=40` and `life/index.html?cells=200`), or once by
`path` and again from another manifest's glob. Entries of the same file
look alike on screen, so two of them in a row look like a repeat.

Time windows (ADR 25) change how many entries are active, so a rule that
works with all of them active can leave nothing when only two are.

## Decision

Two optional fields at the top of a manifest, for random rotation only, both
non-negative integers:

- `no_repeat_entries` (default 1): an entry picked within the last this many
  picks is not picked. 1 is the behaviour so far; 0 lets an entry follow
  itself; 3 means three other entries come in between.
- `no_repeat_pages` (default 0): a page whose file was picked within the
  last this many picks is not picked, whatever its parameters. 0 switches
  the rule off.

An entry is its path with the query the manifest gives it; the parameters
added from `[params]` or the host configuration do not count. A page is its
file. Entries a glob finds count each on their own.

When the rules leave no active entry, they give way step by step until one
is left: first `no_repeat_pages`, then `no_repeat_entries`, each releasing
its oldest pick first. So a file comes back with other parameters before
the same entry comes back, and of two blocked entries the one shown longer
ago comes back. With a single active entry, it is shown again. Weights then
apply among the entries left.

The browser keeps the recent picks, as many as the larger value, by entry
and file. A new plan (a new revision) keeps them; a reload starts empty.
Overrides, interrupts and a page resumed after them are not picks and do
not count. The plan carries both values and each page's `entry` and `file`.

## Consequences

- Rotations with a handful of pages can set `no_repeat_entries` close to
  their number of entries to show nearly all of them before a repeat; a
  value at or above the number of entries makes the rotation run through
  them in a random order, then start a new round in another order.
- The higher the values, the less weights matter: a heavy entry still waits
  its turn. Weights decide among the entries that are allowed.
- Screens remember picks only for themselves; screens on the same
  configuration still show different pages (ADR 9).
- Sequential rotation ignores both fields, as it does `weight`.
