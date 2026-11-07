# 16. Default parameters per configuration

Date: 2026-11-07

## Status

Accepted

## Context

One content repository should be able to look different per screen or per
rotation (e.g. another theme) without changing its pages. Pages and helpers
declare the parameters they accept (ADR 14, ADR 15), so deepsplay knows where a
parameter applies. Some values are known to deepsplay anyway, such as a page's
display time, which pages use for a progress bar and which manifests currently
have to repeat in the page path.

## Decision

deepsplay adds parameters to the page URLs it builds, from several levels.

- A configuration in the host configuration can set
  `params = { theme = "dc" }`; a manifest can set a `[params]` table.
- A parameter definition can ask deepsplay to provide a value with `from`:
  `from = "duration"` is the page's display time from the manifest, in the
  duration format. Further sources (e.g. the screen label, the configuration
  name) can be added later.
- Precedence, highest first:
  1. the query of the page itself (in the manifest path, or in a pinned link),
  2. configuration `params`,
  3. manifest `[params]`,
  4. values provided through `from`,
  5. the definition's `default`, applied by `params.js` in the browser and not
     added to the URL.
- A parameter is added only to pages that declare it, themselves or through a
  helper in `uses`. Pages without a definition get nothing added.
- Pinned pages get the same parameters as in the rotation, from their
  configuration and its manifest; a value provided through `from` is added only
  where it exists (a pinned page has no display time).
- Values are checked against the parameter's definition (type, `values`,
  limits). An invalid value is not passed on. Invalid values, and defaults no
  page declares, are warnings on the status page.

## Consequences

- A repository can be shown with different settings per configuration and per
  manifest, without changes to pages.
- The display time no longer needs repeating in page paths; any level above
  can still override it.
- URLs stay clean: pages only receive parameters they declare.
- Building a plan needs the page definitions and the helper index of the
  revision; they are read once per revision and live for local directories.
