# 27. Page details

Date: 2026-11-08

## Status

Accepted

Amends [24](0024-page-metadata.md).

## Context

`description` is meant to be one short sentence, and the catalog shows it
in the overview of a configuration's pages. Pages still often start with a
long comment explaining where they come from, how they behave and how to
use their parameters. That text is written for people looking at the
catalog, but it is only visible to those reading the source.

## Decision

The parameter block of a page gets one more optional field, `details`;
helper definitions (ADR 15) may have it too.

```toml
description = "Argos, the eyes of the LED wall, looking around and blinking."
details = """
Redrawn from reels/argos.py of the RGB Tetris LED wall.

- an eye idles for 1.5–6 s, then glances (9 in 10) or blinks (1 in 10);
- while closed, the iris may change colour.
"""
```

- Plain text, trimmed; empty counts as not set. Line breaks are kept and
  shown as written (paragraphs, lines starting with `- `); no Markdown. At
  most 5000 characters. Invalid values are warnings, as for the other
  fields of ADR 24.
- The catalog shows it on the page card and on helper cards, collapsed
  under the description. The overview of pages shows only the description.
- `Deepsplay.page()` gets `details` (`null` when not set).
- Guideline for pages: `description` is one sentence, explanations go into
  `details`, comments in the code are about the code.

## Consequences

- What a page does and where it comes from is visible in the catalog
  without reading its source.
- The catalog stays short: long texts are collapsed, the overview uses only
  the description.
- Without Markdown, details cannot have links or emphasis; that can be
  added later without changing the field.
