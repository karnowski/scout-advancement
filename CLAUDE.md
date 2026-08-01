# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

This repository holds Claude skills that help a Scouting America (BSA) troop's
Advancement Chair and Scoutmasters communicate and plan the troop's advancement
program. The intended output is a set of skills (and any supporting scripts/data)
that reason over official advancement rules and requirements.

## Current state

- `README.md` — one-line statement of purpose.
- `docs/` — authoritative reference PDFs (see below).
- `.claude/skills/guide-to-advancement/` — answers advancement policy and
  procedure questions by quoting the Guide to Advancement 2025 with section and
  printed-page citations.
- `.claude/skills/troop-calendar/` — answers "what's on the schedule" questions
  from the troop's published iCal feed, and connects dates to advancement
  planning.

There is no build system or test suite yet. When adding one, update this file
with the real build/lint/test commands — do not assume conventions that aren't
yet established.

### Skill scripts

Scripts are plain Ruby (3.4.5 via asdf), stdlib only — no Gemfile, no gems. Run
them with `ruby scripts/<name>.rb` from the skill directory.

`guide-to-advancement/scripts/gta.rb` shells out to `pdftotext` (poppler) to
build a page-tagged text cache under the skill's `.cache/` (gitignored, rebuilt
on demand). It resolves the Guide's own section numbers to page locations, so
answers can cite `8.0.1.1` alongside a printed page. Two extraction facts it
depends on, both verified against the PDF:

- Printed page + 2 = PDF page. The offset is re-measured from page footers at
  build time rather than hardcoded.
- Body headings wrap across lines and come out truncated, so full section titles
  are read from the front-matter contents listing instead.

`troop-calendar/scripts/calendar.rb` shells out to `curl` and the `sqlite3` CLI
(the `sqlite3` gem is not installed and would violate the stdlib-only rule) to
cache the troop's iCal feed as expanded occurrences in `.cache/calendar.db`. It
re-syncs automatically when the cache is older than six hours. Facts about the
feed it depends on, all verified against it:

- Times come in three flavors: `VALUE=DATE` all-day, UTC (`...Z`), and
  `TZID=America/New_York`. UTC stamps must be converted — a naive parse that
  treats the trailing `Z` as a literal shifts evening events by four hours.
- Recurrence is override-heavy: ~130 `RECURRENCE-ID` events move or rename
  single instances of a series. An override replaces its master's occurrence on
  that date; `EXDATE` and `STATUS:CANCELLED` remove it.
- `DTEND` is exclusive for all-day events but inclusive-in-effect for timed
  ones, so multi-day spans are computed differently for each.

## Reference documents (source of truth)

Advancement logic must trace back to these official documents in `docs/`; do not
rely on memory or general knowledge of Scouting requirements, which change yearly:

- `docs/Scouts-BSA-Requirements-2025.pdf` — the 2025 rank and merit badge
  requirements. Use this for *what* a Scout must do to advance.
- `docs/guide-to-advancement-2025.pdf` — the Guide to Advancement 2025, the
  policy manual governing *how* advancement is administered (boards of review,
  procedures, roles). Use this for process and policy questions.

These are large PDFs (the Guide to Advancement is ~27 MB). Read specific page
ranges rather than loading them whole.

## Domain notes

- "Advancement Chair" and "Scoutmaster" are the primary human roles this project
  serves; skills should frame communication and planning around their needs.
- Requirements are year-versioned. Keep the year explicit (e.g. 2025) so future
  updates can add new versions without silently changing behavior.

## Technology Preferences

- Prefer Ruby 3.4.5 (via asdf) for scripts.
- Use SQLite for any local data storage.
