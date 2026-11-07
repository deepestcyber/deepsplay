# 15. Shared helpers define their parameters

Date: 2026-11-07

## Status

Accepted

## Context

Content repositories have shared helpers, such as a theme script that reads
`theme`, `font` or `duration` for every page using it. Their parameters should
be defined once, like a page's (ADR 14). A helper often needs its values
synchronously, before the first paint (e.g. to add a theme stylesheet while
the page is parsed), so its definition cannot be a separate file loaded at
runtime.

## Decision

A helper defines its parameters inside its own code, by registering them with
`deepsplay.js`:

```js
const P = Deepsplay.helper("theme", `
description = "Shared theme: colours, fonts and a progress bar."

[params.theme]
type    = "enum"
values  = ["default", "neon", "dc"]
default = "default"
`)
```

- `Deepsplay.helper(name, toml)` registers the helper under its name with its
  definition, in the same TOML format as a page block (ADR 14), and returns the
  helper's own parameters from the URL, typed and with defaults applied,
  synchronously.
- deepsplay finds a definition by text search for `Deepsplay.helper("<name>", `
  followed by a backtick, up to the closing backtick; the TOML must not
  contain a backtick. Per revision, deepsplay indexes all helper definitions
  in `pages/` by name.
- A page names the helpers it uses in its block: `uses = ["theme"]`. The
  catalog lists their parameters with the page's own, marked by helper.
- Load order: `deepsplay.js`, then helpers, then the page's own code.
- `Deepsplay.params()` returns only the page's own parameters; a helper's
  parameters are available with `Deepsplay.params("<name>")`.
- If a page and one of its helpers define the same parameter, the page's
  definition wins, with a warning in the catalog. If two helpers in a
  repository register the same name, the first one found counts, with a
  warning.
- An `enum`'s `values` are listed in the definition, even where they mirror
  files (e.g. theme names), so the catalog can offer the choices.

## Consequences

- Helper parameters are defined once and documented for every page using the
  helper.
- deepsplay knows, through `uses`, which pages accept a helper's parameters,
  which defaults per configuration can build on.
- A list such as the theme names must be kept in step with the files by hand.
- Helpers depend on `deepsplay.js` being loaded first; pages using them work
  only when served by deepsplay (as in ADR 14).
