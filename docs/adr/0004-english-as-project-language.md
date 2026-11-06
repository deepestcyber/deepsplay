# 4. English as project language

Date: 2026-11-06

## Status

Accepted

## Context

The team is German speaking. A codebase or interface that mixes languages is
harder to read and maintain than one that commits to a single language.

## Decision

English is the language of code, documentation and the application itself.

- Code: module, function and variable names, comments, `@doc`/`@moduledoc`,
  test descriptions, commit messages.
- Documentation: everything under `docs/`, including these ADRs, and READMEs.
- Application: all text deepsplay itself shows, such as the status page,
  fallback page, error messages and logs.
- British English is accepted as well as American English. Existing text is not
  changed just to switch between the two.
- Pages served from content repositories are not part of the application and
  may use any language.

## Consequences

- One language throughout, with no guessing how a concept is spelled.
- No translation layer for application text for now.
- Mixed British and American spelling may occur; it is not treated as an error.
