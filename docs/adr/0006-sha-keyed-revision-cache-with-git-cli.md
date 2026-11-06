# 6. SHA-keyed revision cache with the git CLI

Date: 2026-11-06

## Status

Accepted

## Context

Screens show content from git repositories. Many screens and configurations can
use the same repository and revision. Branches and tags move, and a screen must
never see a half-written revision. Content has to survive a restart without
network access.

## Decision

Content is served from an on-disk cache keyed by resolved commit SHA, never by
branch or tag name.

- Layout per repository: `mirror.git/` (bare, shallow fetches),
  `rev/<sha>/` (exported tree, read-only, no `.git`), `refs/<ref>` (last good
  SHA), `tmp/` (work in progress, emptied on start).
- A new revision is fetched with depth 1, exported with `git archive` into
  `tmp/`, validated, then moved to `rev/<sha>/` with one atomic rename.
- One supervised writer process per repository serializes fetches.
- The cache lives on a persistent volume. On start, the last good SHA from
  `refs/` is served before the first poll finishes.
- Retention: the current SHA of every ref in use plus the previous
  `keep_revisions` (default 3) per repository.
- Git access uses the `git` command-line tool, not a library. Only `https` and
  `ssh` transports, no submodules, no LFS, no hooks. Credentials reach git only
  through the environment.
- In the test environment, `file` is allowed as well, so tests can use local
  repositories. It is never allowed in dev or prod.

## Consequences

- One export per SHA is shared by all screens and configurations.
- Files of a revision never change, so they can be cached long by browsers.
- A restart without network still shows content.
- The container image needs `git` and `openssh-client`.
- Symlinks in a repository must be removed or rejected at export.
- The allowed transports depend on the environment, so tests cover the
  local-repository path, not the network transports.
