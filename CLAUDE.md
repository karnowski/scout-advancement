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

`target-first-class/scripts/tfc.rb` reads a TroopMaster "Target First Class"
report — a 25-row by 121-column grid of rotated headers and single-glyph marks.
It shells out to `pdftotext -bbox` and rebuilds the grid from word bounding
boxes. Facts about the report it depends on, all verified against the 8/1/2026
one:

- **The report checks itself.** It prints a "Scouts Needing:" tally under every
  column; the script recomputes those counts from the grid it built and compares
  all 121 before reporting anything. Never trust a parse that fails `verify` —
  the grid is dense enough that a misalignment looks entirely plausible.
- `pdftotext -layout` is not an option here, and neither is reading page 1 as an
  image. The marks sit on a ~5.5pt pitch under rotated headers; layout mode
  interleaves the columns, and the image is illegible at that density.
- `X` and `/` both mean complete. `/` is credit that came with a rank award
  rather than a dated sign-off — every Scout-rank holder carries one on Scout 6b.
  Treating `/` as incomplete fails the tally cross-check, which is how this was
  confirmed.
- Rotated headers drop single-part requirement codes ("Scout 5" extracts as bare
  "Scout"), so the 121 column names are hardcoded in `RANKS`. The script asserts
  the count and the per-rank run-lengths (19 / 27 / 37 / 38) and refuses to run
  on a report that disagrees, rather than guessing.

`target-eagle/scripts/te.rb` reads two reports: the "Target Eagle" grid (via
`pdftotext -bbox`, same reason as above — `-layout` interleaves the three rank
blocks) and the "Partial Merit Badges List" (via `pdftotext -layout`, which is
fine on that one). Facts about them it depends on, all verified against the
8/1/2026 and 8/2/2026 reports:

- **The Star block's "SM Conf" column is broken.** TroopMaster leaves it blank
  for every Scout, including Life Scouts whose Star rank is plainly complete. It
  carries no information, so the script excludes it from every count. The rank
  printed in parentheses after each name is authoritative.
- **The cross-check is that printed rank.** This report has no "Scouts Needing:"
  tally, so `verify` asserts instead that every rank block below a Scout's
  printed rank is complete. A misaligned grid fails it immediately.
- **A number means not done.** Participation, Serv Proj, and Lead Pos print the
  amount *remaining* — days, days, and hours. Only an `X` means complete.
- `*` is a completed Eagle-required badge and `+` a completed badge in an Eagle
  category already filled. `+` counts toward the Star and Life "from the required
  list" totals but only as an elective toward Eagle's 14.
- **Blank merit badge slots are a reliable count; the asterisks are not.** A
  Scout with more than seven electives spills the surplus into slots the grid
  then cannot use to show which required badges remain. Read those from the
  partials list, not from the grid.
- Rotated headers are only as tall as the word is long, so "til" and "18" in
  "Months til 18" fall below any height filter. Long words seed the column
  positions; the rest of each phrase is collected by position.
- TroopMaster's badge names differ from the requirements book's ("Citizenship In
  Community" vs "Citizenship in the Community"), so the script matches names
  loosely and `clocks` names any rule that matched nothing.

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
