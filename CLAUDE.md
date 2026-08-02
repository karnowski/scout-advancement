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

Three of the four skills also need **`pdftotext`**, from poppler — it is not a
gem, so `bundle install` alone leaves a fresh clone unable to run them:

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
  Partial Merit Badges List via `pdftotext -layout`.

**Every one of these rests on hard-won facts about its source document** — how
the PDF extracts, what a given mark means, which cross-check catches a misparse.
Those facts live next to the code they constrain, not here: in **`SKILL.md`
under "Facts about the report(s) the script depends on"** for the two TroopMaster
skills, and in **header and inline comments** in `gta.rb` and `calendar.rb`.

**Read them before changing a parser.** Each was established by getting it wrong
first, and none is recoverable by reading the code alone — the code shows what is
done, not the alternative that was tried and silently produced garbage.

Two rules generalize across all of them:

- **Never trust a parse that fails `verify`.** Both TroopMaster grids are dense
  enough that a misalignment yields an entirely plausible-looking plan rather
  than an obvious error. `tfc.rb` checks itself against the report's own "Scouts
  Needing:" tally; `te.rb`, which has no tally row, asserts instead that every
  rank block below each Scout's printed rank is complete.
- **The `pdftotext` invocations are measured, not preferences** — `-bbox` for the
  grids, `-layout` for the partials list, and plain `pdftotext` rather than the
  `pdf-reader` gem for the Guide. Each is justified where it is used. Do not swap
  one without re-measuring against the actual PDF.

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

## Troop 400

Troop 400 is a Scouting America troop in Durham, North Carolina.  The troop's official calendar feed is linked in `README.md`.

**Current Patrols** (as of 2026-08-01)

| Patrol | Nickname | Notes |
| :----- | :------- | :---- |
| BioHazards | Hazards | most are age 14-15, but a few are older |
| Brotherhood of the Flame | Brotherhood | most are age 14-15, but a few are older |
| Screamin' Eagles | Eagles | all are age 13 |
| Seals | _(none)_ | most are age 12-13 |
| Patriotic Squirrels | Squirrels | most are age 11-12 |

**Previous Patrols** (include but not limited to)

| Patrol | Retired | Notes |
| :----- | :------ | :---- |
| Flamingos | Summer 2026 | most aged out, some moved to Brotherhood & BioHazards |
| Skeletons | Early 2025 | big patrol split into Brotherhood & BioHazards |

Additionally, the "Bald Eagles" is the adult scoutmaster patrol.  Note, this patrol name is infrequently used, but when it is, it is always fully-qualified as "Bald Eagles" in order to distinguish it from the similarly-named (and more commonly mentioned) youth patrol.

### How the troop runs advancement

These apply to any advancement planning — rank or merit badge, Target First
Class or Target Eagle:

- **Abbreviations** — the troop uses "SMC" for Scoutmaster Conference and "BoR"
  for Board of Review.
- **Scoutmaster conferences and boards of review are never scheduled as separate
  events.** They happen inside regular meetings, so they never appear on the
  calendar feed. Do not report their absence from it as a finding or a gap.
- **Plan up to 3 conferences or 3 boards per meeting.** The real constraint is
  meeting-night capacity. Total the load, check it fits the meeting nights
  available, and spread it — batching it before a court of honor does not work.
  Conferences and boards can run concurrently.
- **Committee members are almost always also Assistant Scoutmasters.** They can sign
  off merit badge requirements, and they can run boards of review.  Only the
  Scoutmaster can run a Scoutmaster conference.
- **Collapse the closing three requirements** — Scout Spirit, Scoutmaster
  conference, and board of review — into one line, "needs an SMC/BoR meeting".
  At Scout rank, which has no board of review, it is "needs an SMC meeting".
- **"Saturday at the Shed" is an intensive sign-off and training session,** not a
  work day: roughly 3–4 hours with 6–7 adult leaders signing off. Split the
  leader roster between Target First Class rank sign-offs and Target Eagle merit
  badge sign-offs, plan ~3 rotating stations, and expect it to absorb about 3
  conferences and 3 boards as well. Check how many fall in the planning window —
  there may be only one.

## Technology Preferences

- Prefer Ruby 3.4.5 (via asdf) for scripts.
- Use SQLite for any local data storage, via the `sqlite3` gem.
- Manage gems with Bundler and the repo-root `Gemfile`.
