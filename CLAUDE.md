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

- `Gemfile` / `Gemfile.lock` — the gems the skill scripts depend on.
- `.rubocop.yml` / `.rubocop_todo.yml` — lint configuration (see below).

There is no test suite yet. When adding one, update this file with the real
test command — do not assume conventions that aren't yet established.

### Linting

    bundle exec rubocop        # lint everything
    bundle exec rubocop -a     # apply the safe autocorrections

RuboCop skips hidden directories, so `.claude/skills/*/scripts/*.rb` is named
explicitly in `AllCops: Include`. Without that entry it silently inspects
nothing but the `Gemfile` and still reports success.

`.rubocop.yml` holds the settled style; `.rubocop_todo.yml` holds what predates
the linter. The todo file grandfathers four over-long methods **by name**
(`AllowedMethods`) rather than excluding whole files, so the metrics still apply
to everything else — keep it that way when regenerating, since
`rubocop --auto-gen-config` writes file-level excludes instead. Delete a name
from the todo file when its method is broken up; don't add new ones.

### Dependencies

Scripts are Ruby 3.4.5 (via asdf) and use gems, declared in the repo-root
`Gemfile`. Install with `bundle install`.

Prefer a well-maintained gem over hand-rolling a parser for a standard format —
iCalendar, RRULE, and PDF text extraction are all specified formats with edge
cases that are easy to get subtly wrong. Keep the dependency list short and
justified; add a gem when it removes real logic, not for convenience wrappers
around one or two stdlib calls.

Scripts still run as `ruby scripts/<name>.rb` from the skill directory: each one
sets `BUNDLE_GEMFILE` to the repo-root `Gemfile` and requires `bundler/setup`
before anything else, so no `bundle exec` prefix is needed.

### Skill scripts

`guide-to-advancement/scripts/gta.rb` shells out to `pdftotext` (poppler) to
build a page-tagged text cache under the skill's `.cache/` (gitignored, rebuilt
on demand). It resolves the Guide's own section numbers to page locations, so
answers can cite `8.0.1.1` alongside a printed page. Three extraction facts it
depends on, all verified against the PDF:

- Printed page + 2 = PDF page. The offset is re-measured from page footers at
  build time rather than hardcoded.
- Body headings wrap across lines and come out truncated, so full section titles
  are read from the front-matter contents listing instead.
- `pdftotext` is deliberate here and should not be swapped for the `pdf-reader`
  gem. On *this* PDF, pdf-reader interleaves the two columns line by line and
  emits headings with no inter-word spaces (`8.0.1.1NotaRetestor`), which makes
  section titles unrecoverable. pdf-reader is fine on the single-column
  `docs/Scouts-BSA-Requirements-2025.pdf`.

`troop-calendar/scripts/calendar.rb` fetches the troop's iCal feed over
`net/http` and caches it as expanded occurrences in `.cache/calendar.db`. It
re-syncs automatically when the cache is older than six hours. It uses
`icalendar` to parse the feed, `rrule` to expand recurrence rules, `tzinfo` to
convert to calendar-local time, and `sqlite3` for the cache. Facts about the
feed it depends on, all verified against it:

- Times come in three flavors: `VALUE=DATE` all-day, UTC (`...Z`), and
  `TZID=America/New_York`. Everything stored is calendar-local wall clock, so
  UTC stamps are converted through `tzinfo` — never through the machine's own
  timezone.
- Recurrence is override-heavy: ~130 `RECURRENCE-ID` events move or rename
  single instances of a series. The gems do not model this, so the script does:
  an override replaces its master's occurrence on that date; `EXDATE` and
  `STATUS:CANCELLED` remove it.
- `RRULE:...;UNTIL=...Z` is a UTC instant, not a date. Several series end at
  `T045959Z`, which is 23:59:59 the previous day in Eastern time; truncating
  `UNTIL` to its date part yields one occurrence too many per series.
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
- Use SQLite for any local data storage, via the `sqlite3` gem.
- Manage gems with Bundler and the repo-root `Gemfile`.
