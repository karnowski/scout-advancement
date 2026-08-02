# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

This repository holds Claude skills that help a Scouting America (BSA) troop's
Advancement Chair and Scoutmasters communicate and plan the troop's advancement
program. The intended output is a set of skills (and any supporting scripts/data)
that reason over official advancement rules and requirements.

## Privacy — this repository is public

`github.com/karnowski/scout-advancement` is a **public** repository, and most of
what this project reads is a roster of minors.  Nothing that names a Scout may
ever be committed.  That covers:

- TroopMaster reports (Target First Class, Target Eagle, Partial Merit Badges
  List) and any other export naming Scouts.
- The plans generated from them, in `plans/`.
- **Commit messages, branch names, and PR descriptions** — summarize a change as
  "regenerate the Target Eagle plan", never by who is in it.

`.gitignore` covers `plans/`, `reports/`, and every PDF outside `docs/`.  Treat
that as a backstop, not as permission to stop paying attention: never
`git add -f` past it, and never paste report contents into a tracked file.  If a
Scout's name has to appear in something committed — a test fixture, an example
in a SKILL.md — invent one.

Nothing here restricts what the skills may *say* in a session.  Names belong in
plans and in answers to the Advancement Chair; they just never reach git.

## Current state

- `README.md` — statement of purpose and a catalog of the skills.
- `docs/` — authoritative reference PDFs (see below).
- `.claude/skills/guide-to-advancement/` — answers advancement policy and
  procedure questions by quoting the Guide to Advancement 2025 with section and
  printed-page citations.
- `.claude/skills/scout-req/` — looks up rank, merit badge, and award
  requirement text in Scouts BSA Requirements 2025, and is deliberately loud
  about any merit badge that printing cannot answer for.
- `.claude/skills/troop-calendar/` — answers "what's on the schedule" questions
  from the troop's published iCal feed, and connects dates to advancement
  planning.
- `.claude/skills/target-first-class/` — turns a TroopMaster "Target First
  Class" report into an advancement plan and to-do list for the Scouts working
  toward Scout through First Class.
- `.claude/skills/target-eagle/` — turns a TroopMaster "Target Eagle" report
  plus the matching "Partial Merit Badges List" into an advancement plan and
  to-do list for the Scouts working toward Star, Life, and Eagle.
- `reports/` — where to drop the TroopMaster PDFs a skill is asked to read.
  Gitignored; look here first when a skill needs a report and none was named.
- `plans/` — generated advancement plans, gitignored.  Named
  `<skill>-YYYY-MM-DD.md`, dated from the report they read, with an optional
  `-SCOPE` suffix when a run covers a subset rather than the whole report
  (`target-first-class-2026-08-01-seals.md` is the Seals patrol).  Two runs of
  the same scope on the same report overwrite; don't invent `-backup` names.

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

Four of the five skills also need **`pdftotext`**, and `scout-req` additionally
needs **`pdftohtml`**. Both come from poppler, and neither is a gem, so
`bundle install` alone leaves a fresh clone unable to run them:

    brew install poppler

Prefer a well-maintained gem over hand-rolling a parser for a standard format —
iCalendar, RRULE, and PDF text extraction are all specified formats with edge
cases that are easy to get subtly wrong. Keep the dependency list short and
justified; add a gem when it removes real logic, not for convenience wrappers
around one or two stdlib calls.

Scripts still run as `ruby scripts/<name>.rb` from the skill directory: each one
sets `BUNDLE_GEMFILE` to the repo-root `Gemfile` and requires `bundler/setup`
before anything else, so no `bundle exec` prefix is needed.

### Skill scripts

Each skill is a single script under `.claude/skills/<skill>/scripts/`:

- **`gta.rb`** (guide-to-advancement) — shells out to `pdftotext` to build a
  page-tagged text cache under the skill's `.cache/` (gitignored, rebuilt on
  demand), and resolves the Guide's own section numbers to printed pages so an
  answer can cite `8.0.1.1` alongside a page.
- **`calendar.rb`** (troop-calendar) — fetches the iCal feed over `net/http`,
  expands recurrence with `rrule`, converts to calendar-local time with
  `tzinfo`, and caches occurrences in `.cache/calendar.db` via `sqlite3`,
  re-syncing when the cache is over six hours old.
- **`tfc.rb`** (target-first-class) — rebuilds a 25-row by 121-column grid of
  rotated headers and single-glyph marks from `pdftotext -bbox` output.
- **`te.rb`** (target-eagle) — the same for the Target Eagle grid, plus the
  Partial Merit Badges List via `pdftotext -layout`. Its `badges` subcommand
  prints the in-progress badge names one per line for `req.rb check` to read.
- **`req.rb`** (scout-req) — indexes every rank, merit badge, and award in the
  requirements book by reading font sizes out of `pdftohtml -xml`, since the book
  numbers nothing and its headings are otherwise indistinguishable from body
  text. Body text comes from plain `pdftotext`. Exits `3` — not `1` — when a
  question needs requirements the 2025 printing does not carry; that status is
  the skill's whole reason for existing, so preserve it. `check` is the same
  guard over a list of names, silent unless one is a problem.

**Every one of these rests on hard-won facts about its source document** — how
the PDF extracts, what a given mark means, which cross-check catches a misparse.
Those facts live next to the code they constrain, not here: in **`SKILL.md`
under "Facts about the report(s)/book the script depends on"** for the two
TroopMaster skills and `scout-req`, and in **header and inline comments** in
`gta.rb` and `calendar.rb`. `req.rb` carries a second copy in its own header,
next to the code the facts constrain.

**Read them before changing a parser.** Each was established by getting it wrong
first, and none is recoverable by reading the code alone — the code shows what is
done, not the alternative that was tried and silently produced garbage.

Two rules generalize across all of them:

- **Never trust a parse that fails `verify`.** Both TroopMaster grids are dense
  enough that a misalignment yields an entirely plausible-looking plan rather
  than an obvious error. `tfc.rb` checks itself against the report's own "Scouts
  Needing:" tally; `te.rb`, which has no tally row, asserts instead that every
  rank block below each Scout's printed rank is complete. `req.rb` reconciles
  its merit badge index against the requirements book's own Merit Badge Library
  page, and checks the badges run alphabetically under the right A–Z tab.
- **The `pdftotext` invocations are measured, not preferences** — `-bbox` for the
  grids, `-layout` for the partials list, plain `pdftotext` rather than the
  `pdf-reader` gem for the Guide, and `pdftohtml -xml` alongside plain
  `pdftotext` for the requirements book. Each is justified where it is used. Do
  not swap one without re-measuring against the actual PDF.

### `scout-req` is the only reader of the requirements book

No other skill opens `docs/Scouts-BSA-Requirements-2025.pdf`, and none should.
Reading it directly gets the text but not the guard: a merit badge introduced or
revised after that printing produces a fluent, specific, correctly-cited, wrong
answer, and there is nothing downstream that can catch it. Route requirement
lookups through `scout-req`, which exits 3 instead.

Skill directories are siblings, so a script calls another by relative path. Every
script resolves its own paths from `__dir__`, so the working directory does not
matter:

    ruby ../scout-req/scripts/req.rb show "Personal Management"
    ruby scripts/te.rb badges R.pdf --partials P.pdf | ruby ../scout-req/scripts/req.rb check

`target-eagle` runs that second line before it plans anything, because a
TroopMaster report is exactly where a post-2025 badge enters unannounced.

The Ruby tables that name requirements — `RANKS` in `tfc.rb`, `CLOCKS`,
`BLOCKS`, and `BADGE_PREREQS` in `te.rb` — are **match keys, not a second copy
of the book.** They exist so a parser can identify a column or find the Scouts on
a clock. Their labels are far too short to plan from and are not maintained
against the book; the text that governs comes from `scout-req`. Do not quote one
into a plan, and do not delete them either — the parsers do not work without
them.

## Reference documents (source of truth)

Advancement logic must trace back to these official documents in `docs/`; do not
rely on memory or general knowledge of Scouting requirements, which change yearly:

- `docs/Scouts-BSA-Requirements-2025.pdf` — the 2025 rank and merit badge
  requirements, *what* a Scout must do to advance. **Reach it through the
  `scout-req` skill, not by opening the file** (see above); that skill is what
  knows the 2025 printing's limits.
- `docs/guide-to-advancement-2025.pdf` — the Guide to Advancement 2025, the
  policy manual governing *how* advancement is administered (boards of review,
  procedures, roles). Use this for process and policy questions, via the
  `guide-to-advancement` skill.

These are large PDFs (the Guide to Advancement is ~27 MB). Read specific page
ranges rather than loading them whole.

## Domain notes

- "Advancement Chair" and "Scoutmaster" are the primary human roles this project
  serves; skills should frame communication and planning around their needs.
- Requirements are year-versioned. Keep the year explicit (e.g. 2025) so future
  updates can add new versions without silently changing behavior.

## Troop settings

Troop-specific facts — the troop's name, location, patrols, and how it runs
advancement (SMC/BoR abbreviations, per-meeting capacity, sign-off
authority, recurring events) — live in `TROOP-SETTINGS.md`, not here.  That
file is gitignored so a fork of this project doesn't accidentally commit
another troop's details; `TROOP-SETTINGS.md.example` is the checked-in
template.  Skills that need troop context should read `TROOP-SETTINGS.md`.

## Technology Preferences

- Prefer Ruby 3.4.5 (via asdf) for scripts.
- Use SQLite for any local data storage, via the `sqlite3` gem.
- Manage gems with Bundler and the repo-root `Gemfile`.
