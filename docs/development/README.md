# Development plans

This directory tracks planned and ongoing work: phases, build packages and
similar units. Each unit has one file with its parts and their progress.

## Naming

`NNNN-short-name-state.md`

- `NNNN`: zero-padded, strictly increasing number, never reused. It gives the
  order of the units.
- `short-name`: kebab-case, e.g. `phase1`.
- `state`: `active` while work is ongoing, `completed` when done. On
  completion, the file is renamed; number and name stay the same.

Example: `0001-phase1-active.md` becomes `0001-phase1-completed.md`.

## Content

- A short introduction with links to the relevant docs and ADRs.
- An overview table of the parts (e.g. slices) with their status: `open`,
  `in progress` or `done`.
- One section per part with status, goal and, once done, what was built and
  notes worth keeping.

Update the file as part of the work: a part is not done until its status and
notes are updated.

Decisions with lasting effect go into [ADRs](../adr/), not here.
