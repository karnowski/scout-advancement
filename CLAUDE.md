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

`.gitignore` covers `plans/`, `reports/`, and every PDF outside `references/`.  Treat
that as a backstop, not as permission to stop paying attention: never
`git add -f` past it, and never paste report contents into a tracked file.  If a
Scout's name has to appear in something committed — a test fixture, an example
in a SKILL.md — invent one.

Nothing here restricts what the skills may *say* in a session.  Names belong in
plans and in answers to the Advancement Chair; they just never reach git.

## Current state

- `README.md` — statement of purpose and a catalog of the skills.
- `references/` — authoritative reference PDFs (see below).
- `.claude/skills/guide-to-advancement/` — answers advancement policy and
  procedure questions by quoting the Guide to Advancement 2025 with section and
  printed-page citations.
- `.claude/skills/scout-req/` — looks up rank, merit badge, and award
  requirement text in Scouts BSA Requirements 2025, layers on the merit badge
  changes effective Jan. 1, 2026, and is deliberately loud about any badge
  neither document can answer for.
- `.claude/skills/troop-calendar/` — answers "what's on the schedule" questions
  from the troop's published iCal feed, and connects dates to advancement
  planning.
- `.claude/skills/target-first-class/` — turns a TroopMaster "Target First
  Class" report into an advancement plan and to-do list for the Scouts working
  toward Scout through First Class.
- `.claude/skills/target-eagle/` — turns a TroopMaster "Target Eagle" report
  plus the matching "Partial Merit Badges List" into an advancement plan and
  to-do list for the Scouts working toward Star, Life, and Eagle.
- `.claude/skills/mbc/` — answers who in the troop counsels a given merit badge,
  from the TroopMaster "MBC Grouped By Badge" report, and which badges have no
  counselor at all.
- `.claude/skills/eagle-req/` — answers Eagle Scout service project questions
  (the proposal, plan, fundraising application, report, and approvals) from the
  Eagle Scout Service Project Workbook 2023a.
- `.claude/skills/badge-inventory/` — answers how many rank patches, rank pins,
  position patches, awards, and merit badge patches the troop has on hand, from
  the troop's badge inventory Google Sheet.
- `.claude/skills/coh-shopping-list/` — turns a TroopMaster "Court Of Honor"
  report into a Scout Shop order, subtracting what the troop already holds.
- `.claude/skills/import-individual-history/` — reads a TroopMaster "Individual
  History" report into a local SQLite database, one record per Scout, each
  stamped with the date of the report it came from.  It stores; it does not
  plan.
- `.claude/skills/individual-history/` — answers questions about what that
  database holds, for one Scout or across the troop: what a rank still needs,
  Eagle-required slot coverage, position-of-responsibility tenure, idle
  partials, and the awards, National Outdoor Award segments, training courses
  and Order of the Arrow standing the report also carries.  It reads; it does
  not plan.
- `reports/` — where to drop the TroopMaster PDFs a skill is asked to read.
  Gitignored; look here first when a skill needs a report and none was named.
- `plans/` — generated advancement plans, gitignored.  Named
  `<skill>-YYYY-MM-DD.md` (`coh-shopping-list-2026-08-17.md`), dated from the
  report they read, with an optional `-SCOPE` suffix when a run covers a subset
  rather than the whole report
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

Six of the nine skills also need **`pdftotext`**, and `scout-req` additionally
needs **`pdftohtml`** — the latter for `req.rb`; the sibling `changes.rb` needs
only `pdftotext`, plus the `pdf-reader` gem for the table's drawn borders.  Both
come from poppler, and neither is a gem, so `bundle install` alone leaves a
fresh clone unable to run them:

    brew install poppler

`troop-calendar`, `eagle-req`, and `badge-inventory` need neither.  `eagle-req`
in particular reads its PDF with the `pdf-reader` gem *because* poppler gets
that file wrong; see below.

Prefer a well-maintained gem over hand-rolling a parser for a standard format —
iCalendar, RRULE, CSV, and PDF text extraction are all specified formats with
edge cases that are easy to get subtly wrong. Keep the dependency list short and
justified; add a gem when it removes real logic, not for convenience wrappers
around one or two stdlib calls.

**`rexml` and `csv` are bundled gems, not default ones**, so both must stay
declared in the `Gemfile` — under `bundler/setup` an undeclared bundled gem
fails to load outright, with a `LoadError` that reads like the gem is missing
from the system.

Scripts still run as `ruby scripts/<name>.rb` from the skill directory: each one
sets `BUNDLE_GEMFILE` to the repo-root `Gemfile` and requires `bundler/setup`
before anything else, so no `bundle exec` prefix is needed.

### Skill scripts

Each skill has one script under `.claude/skills/<skill>/scripts/` — except
`scout-req`, which has one per document it reads, and `individual-history`,
whose script reads the database `import-individual-history` writes rather than a
document of its own:

- **`gta.rb`** (guide-to-advancement) — shells out to `pdftotext` to build a
  page-tagged text cache under the skill's `.cache/` (gitignored, rebuilt on
  demand), and resolves the Guide's own section numbers to printed pages so an
  answer can cite `8.0.1.1` alongside a page.
- **`calendar.rb`** (troop-calendar) — fetches the iCal feed over `net/http`,
  expands recurrence with `rrule`, converts to calendar-local time with
  `tzinfo`, and caches occurrences in `.cache/calendar.db` via `sqlite3`,
  re-syncing when the cache is over six hours old.
- **`tfc.rb`** (target-first-class) — rebuilds a 25-row by 121-column grid of
  rotated headers and single-glyph marks from `pdftotext -bbox` output. Its
  `clocks` and `banked` subcommands carry the skill's two standing analyses —
  where each Scout sits on the sequential fitness chain, and who has program work
  signed above a rank they cannot yet be awarded — so those are not re-derived by
  hand from `json` on every run. `--exclude NAME` drops Scouts who have left the
  troop from every count; it applies *after* `verify`, so the tally cross-check
  still sees the full printed grid.
- **`te.rb`** (target-eagle) — the same for the Target Eagle grid, plus the
  Partial Merit Badges List via `pdftotext -layout`. Its `badges` subcommand
  prints the in-progress badge names one per line for `req.rb check` to read.
- **`mbc.rb`** (mbc) — parses the "MBC Grouped By Badge" report with
  `pdftotext -layout` into `.cache/mbc.db`, and answers counselor lookups in
  both directions.  The report lists only badges that *have* a counselor, so it
  also loads the full badge list from `req.rb list --kind badge` — that is what
  distinguishes "nobody counsels it" from "not a merit badge". `EAGLE_SLOTS`
  carries the Eagle-required slots as match keys, because a badge absent from
  the report carries no Eagle star to read. It holds **13 slots, not the 14 of
  Eagle requirement 3** — the troop does not count Citizenship in Society (see
  `history.rb` below), and this table must stay in step with the one there.
- **`req.rb`** (scout-req) — indexes every rank, merit badge, and award in the
  requirements book by reading font sizes out of `pdftohtml -xml`, since the book
  numbers nothing and its headings are otherwise indistinguishable from body
  text. Body text comes from plain `pdftotext`. Exits `3` — not `1` — when a
  question needs requirements **neither the 2025 printing nor the 2026 change
  list** carries; that status is the skill's whole reason for existing, so
  preserve it. A badge merely *changed* for 2026 does **not** exit 3 — `show`
  prints the updated text after the 2025 entry and `check` prints a note,
  because the skill can answer for it. `check` is the same guard over a list of
  names, quiet unless something needs saying.
- **`changes.rb`** (scout-req) — reads Scouting America's merit badge changes
  effective Jan. 1, 2026 out of a 38-page three-column table. It takes the row
  and column boundaries from the table's **drawn borders** rather than from the
  text, because no text-based rule works: the gap between rows is *smaller* than
  the gap inside one. `pdf-reader` supplies the rectangles and `pdftotext
  -bbox-layout` the words. The decisive detail is that a border is **black**
  while Word's cell shading is painted as hairline strips of the same width —
  colour is the only thing that tells a boundary from a background.
- **`eagle.rb`** (eagle-req) — reads the Eagle Scout Service Project Workbook
  with `pdf-reader` and **repairs the PDF's text layer as it goes**. Eight of the
  workbook's eleven embedded Arial CID fonts carry an incomplete ToUnicode CMap,
  so every off-the-shelf extractor silently *deletes* letters — Eagle Scout
  requirement 5 comes out of `pdftotext` as "W ile a i e Scout la evelo a give
  lea er i to ot er". `RepairedCMap` fills the holes from the glyph order the
  file's own CMaps prove (`CID = ASCII − 29`), scoped to Arial Type0 fonts only.
  Its `verify` re-derives that rule from the PDF and extracts the workbook a
  second time with the repair off, to show what it is worth.
- **`coh.rb`** (coh-shopping-list) — parses the Court Of Honor report with
  `pdftotext -layout` and subtracts the counts `inventory.rb` reports. The
  report's Awards Summary is two columns of items separated by nothing but the
  column gap, and **Special Awards is the one section with no item code**, so
  the sections are split on runs of spaces and sliced by three or by two
  accordingly. Everything else follows from the troop distributing on two
  clocks: rank and position patches go out the day they are earned, so a rank in
  the report calls for two *pins* and never a patch, and rank stock is rebuilt
  against the `RANK_BANDS` min/max rather than against the report. Because a
  patch that left the box before its row was counted is still counted,
  `rank_stock` subtracts any award dated after `Last Checked`.  The sheet's
  `Out of Date` column is carried through the same way `inventory.rb` reports
  it — **never folded into a count**: a retired-design patch is not in
  `on_hand`, never reduces a shortfall, and never takes a line off the order.
  It rides along on `Stock` only so `Notes.retired` can say it is there, with
  the sheet's note on what is wrong with it, and leave the "will an older
  border do" call to the Advancement Chair.  **Merit badge
  cards are the one line the sheet cannot answer for**: one goes out with every
  badge, so the need is the report's own merit badge total, but nobody counts
  the drawer and the Scout Shop sells them by the package — so the buy is that
  total divided by `CARDS_PER_PACKAGE` and rounded up, an `Uncounted` stock
  keeps it out of the "row missing from the sheet" notes, and packages are never
  added into the count of single patches.  Every list it prints is ordered by one
  `Item#sort_key`: ranks lowest-to-highest via
  `RANK_ORDER` (the report's two-column summary reads out in page order, not
  advancement order), everything else grouped merit badge patches, then cards,
  then awards, and alphabetical within each.
- **`individual_history.rb`** (import-individual-history) — rebuilds the
  Individual History report's tables from `pdftotext -bbox-layout` and stores
  them in `.cache/individual-history.db`. The report is drawn column by column,
  so every cell is its own `<line>` and a row is the set of lines sharing a
  `yMin` — read top to bottom the columns interleave. `-layout` cannot be used
  at all: in the merit badge list a long name runs into its own date with a
  single space between them, the same as the space inside the name. Rows also
  admit a line whose band sits *inside* the band already open, because a value
  TroopMaster shrank to fit — a `Position:` naming four jobs — is reported as
  starting *below* the label beside it. A block heading is not always just the
  rank: it carries TroopMaster's own count of the Eagle-required badges still
  wanted (`Star (2 Eagle MB remaining)`) and, past three Palms, an ordinal
  (`2nd Bronze Palm`), and a parser that matches headings against a fixed list
  of names misses both **silently** — the rows below join the previous block and
  the heading is filed as an annotation on the requirement above it. Its
  `badges` subcommand prints every badge name for `req.rb check` to read, and
  its freshness is **per Scout** — a record carries the date printed on the
  report that supplied it, so an import of an older report leaves a Scout alone
  rather than rewinding them.
- **`history.rb`** (individual-history) — the only *reader* of
  `individual-history.db`; it never writes and never opens a PDF.  Three of its
  answers carry logic that is wrong if reinvented casually.  **Eagle coverage is
  computed against `EAGLE_SLOTS`, never from the `eagle_required` column** —
  three of the slots are OR-groups, so slots are not badges, and a badge the
  report never names carries no flag at all.  **POR tenure is a
  union of intervals clipped to the Scout's own `rank_date`** — the book reads
  "While a Star Scout, serve actively... for six months", so earlier service
  counts toward the rank it was served under, and a Scout holding Bugler and
  Patrol Leader over the same six months served six months rather than twelve.
  `POR_MONTHS` and `EAGLE_SLOTS` are match keys and thresholds, not the book;
  `EAGLE_SLOTS` deliberately duplicates the table in `mbc.rb` and the two must
  stay in step.

  Third, and the one that departs from the printed book: **`EAGLE_SLOTS` holds
  13 slots, because the troop does not count Citizenship in Society as
  Eagle-required.**  CiS counts toward the 21 badges Eagle asks for and fills no
  required slot.  Scouts BSA Requirements 2025 says otherwise — it lists CiS as
  (d) of 14 at Eagle requirement 3 — so `scout-req` will quote 14 and is not
  wrong to; the 2026 change list covers merit badge *requirements* only and is
  silent on the rank by construction.  **This is a decision of the troop's, not
  a reading of a document**, and it rests on the whole-troop report: every
  Eagle-remaining figure TroopMaster prints reproduces exactly as `13 - filled`
  and none at 14; CiS is the only badge that ever carries `#` and the only
  Citizenship badge that never carries `*`; and with CiS dropped the report's
  stars and the table agree exactly.  `eagle` still prints TroopMaster's figure
  beside its own — they now agree for every Scout, so that line is a **guard**:
  a mismatch means one of the two lists has moved.  Do not "restore" the 14th
  slot to match the book without raising it with the Advancement Chair.
- **`inventory.rb`** (badge-inventory) — downloads every tab of the troop's
  badge inventory Google Sheet as CSV over `net/http` and caches the rows in
  `.cache/inventory.db` via `sqlite3`, re-syncing when the cache is over six
  hours old. The sheet is link-shared, so no Google credentials are involved.
  Three things about it are not guessable: the CSV endpoint takes a `gid` but
  will not enumerate the tabs, so the tab names and gids are scraped from the
  sheet's `/htmlview` page; blank rows are *section breaks*, not end-of-data,
  so a parser that stops at the first one drops every rank pin; and the Merit
  Badges tab's `Out of Date` column is **not** part of `Count` — the two are
  kept apart on the sheet (Athletics reads 1 and 2), so summing them claims
  patches the troop cannot hand out. It is carried as its own field and added
  into no total. `INVENTORY_TABS` names the four tabs that are the inventory,
  since the sheet also carries the Advancement Chair's working tabs; those are
  skipped and named, while one of the four going *missing* stays fatal.

**Every one of these rests on hard-won facts about its source** — how the PDF
extracts, what a given mark means, which column cannot be trusted, which
cross-check catches a misparse.  Those facts live next to the code they
constrain, not here: in **`SKILL.md` under "Facts about the ... the script
depends on"** for the five TroopMaster skills, `scout-req` (which has one such
section per document), `eagle-req`, `badge-inventory`, and `individual-history`
(whose source is the database rather than a document), and in **header and
inline comments** in `gta.rb` and `calendar.rb`.  `req.rb`, `changes.rb`,
`eagle.rb`, `inventory.rb`, `coh.rb`, `individual_history.rb`, and `history.rb`
each carry a second copy in their own header, next to the code the facts
constrain.

**Read them before changing a parser** — or, for `history.rb`, before changing
what an answer is computed from. Each was established by getting it wrong
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
  `changes.rb` has no tally row, so it builds one: every word inside the table
  must be claimed by exactly one row, every page's first row must be the
  repeated column header, and every badge it names must resolve against
  `req.rb list --kind badge`.  `coh.rb` is the one report that *does* print its
  own tally, so it uses it three ways at once: each Awards Summary section's
  declared total, the sum of that section's line items, and an independent
  re-tally of the per-Scout detail pages must all agree, item by item.
  `individual_history.rb` has the same kind of tally — each Scout's badge list
  is headed `Merit Badges : N` — and uses it twice over: N against the rows
  parsed, and every badge named in a Star/Life/Eagle slot against that list
  *with the same date*, since the two are printed from the same data by
  different code paths. It also insists every cell on every page is claimed by
  some section, that completed ranks are a prefix of the ladder and agree with
  the header, and that a rank never has both a completion date and a printed
  requirement block — the report prints blocks only for ranks not yet earned.
  The tally is the one check the report can withhold: a Scout who has just
  joined gets **no Merit Badges section at all**, not a heading reading zero, so
  a missing tally is a note unless badges were parsed anyway.
  `mbc.rb` has no tally either, so it leans on what a *grouped* report
  guarantees — every badge staffed, names alphabetical, each counselor's phone
  identical everywhere, every phone-code line accounted for. `eagle.rb` has no
  report structure to lean on at all, so it verifies the *decoding*: that the
  glyph-order rule still holds across every CMap in the file, that no CID is
  still being dropped, that the page labels it assigns match the footers the
  pages print, and that ten canary passages — each destroyed without the repair
  — survive it.  `inventory.rb` has no tally row either, so it leans on what a
  hand-kept inventory guarantees: every row named, counted, and dated, no date
  unparseable or in the future, no duplicate name within a tab, and every badge
  in the book present on the Merit Badges tab via `req.rb list --kind badge`.
  Post-2025 badges, absent rank/pin rows, out-of-date patches, and the skipped
  non-inventory tabs are reported as *notes*, not failures — every one is a
  true fact about the troop rather than a parse error.
- **The `pdftotext` invocations are measured, not preferences** — `-bbox` for the
  grids, `-layout` for the partials list and the MBC report, plain `pdftotext`
  rather than the `pdf-reader` gem for the Guide, `pdftohtml -xml` alongside
  plain `pdftotext` for the requirements book, and `-bbox-layout` for both the
  2026 change table and the Individual History report, whose columns only
  coordinates can separate.  Each is justified where it is used.  Do not swap
  one without re-measuring against the actual PDF.  The Eagle
  project workbook is the exception that proves it: **poppler cannot read that
  file correctly at all**, which is why `eagle.rb` uses `pdf-reader` and decodes
  the fonts itself.

### `scout-req` is the only reader of the requirements book and the change list

No other skill opens `references/Scouts-BSA-Requirements-2025.pdf` or
`references/Major-Requirement-Changes-as-of-1_1_2026.pdf`, and none should.
Reading either directly gets the text but not the guard, and the two are only
correct together: **65 of the book's 139 merit badges changed effective Jan. 1,
2026**, so the book alone now gives a fluent, specific, correctly-cited, wrong
answer for nearly half of them, and nothing downstream can catch it. Route
requirement lookups through `scout-req`, which prints the 2026 text alongside
the 2025 text and exits 3 when neither document carries the answer.

### `eagle-req` is the only reader of the Eagle project workbook

Same rule, different failure. No other skill opens
`references/EagleProjectWorkbook2023a.pdf`. Reading it with `pdftotext`, or with
the Read tool's text path, returns prose with letters silently missing — it
still looks quotable, and the missing letters change what the sentence says.
Only `eagle.rb` repairs it. Reading a *page image* with the Read tool is fine,
and is what the SKILL.md tells you to do for the two pages whose side-by-side
boxes interleave.

Skill directories are siblings, so a script calls another by relative path. Every
script resolves its own paths from `__dir__`, so the working directory does not
matter:

    ruby ../scout-req/scripts/req.rb show "Personal Management"
    ruby scripts/te.rb badges R.pdf --partials P.pdf | ruby ../scout-req/scripts/req.rb check

`target-eagle` runs that second line before it plans anything, because a
TroopMaster report is exactly where a post-2025 badge enters unannounced.

`coh.rb` pipes `badges` through `req.rb check` for a different reason than
`target-eagle` does: a patch does not change when its requirements do, so the
2026 note is irrelevant to an order, but **exit 3 flags a badge the inventory
sheet very likely has no row for** — a patch the troop may never have stocked,
which would otherwise read as "not tracked" and be mistaken for a zero.

`individual_history.rb` pipes `badges` through `req.rb check` for the same
reason `target-eagle` does, and more urgently: a TroopMaster report is where a
post-2025 badge enters unannounced, and 45 of the 95 badges on the troop's
current whole-troop Individual History report changed effective Jan. 1, 2026, so
the 2025 text is out of date for nearly half of them.

`mbc.rb` and `inventory.rb` are the other consumers, and both use `req.rb list
--kind badge` rather than `check` — they need the *whole* badge list, because
"we have no counselor for that badge" / "we hold no patches for that badge" and
"that is not a badge" are different answers, and only the book can tell them
apart. Neither reports requirement text, so neither propagates exit 3; each
prints a note on a badge the 2025 printing does not carry and says to get the
requirements from scouting.org.

The Ruby tables that name requirements — `RANKS` in `tfc.rb`, `CLOCKS`,
`BLOCKS`, and `BADGE_PREREQS` in `te.rb`, `EAGLE_SLOTS` in `mbc.rb`,
`RANK_LADDER` and `PALM_METALS` in `individual_history.rb`, and `EAGLE_SLOTS`
and `POR_MONTHS` in `history.rb` — are **match keys, not a second copy of the
book.**  The two `EAGLE_SLOTS` tables are the one place the repo deliberately
*departs* from the book rather than abbreviating it, and the reason is written
out at `history.rb` above. They exist so a parser can identify a column or find the Scouts on
a clock. Their labels are far too short to plan from and are not maintained
against the book; the text that governs comes from `scout-req`. Do not quote one
into a plan, and do not delete them either — the parsers do not work without
them.

## Reference documents (source of truth)

Advancement logic must trace back to these official documents in `references/`; do not
rely on memory or general knowledge of Scouting requirements, which change yearly:

- `references/Scouts-BSA-Requirements-2025.pdf` — the 2025 rank and merit badge
  requirements, *what* a Scout must do to advance. **Reach it through the
  `scout-req` skill, not by opening the file** (see above); that skill is what
  knows the 2025 printing's limits.
- `references/Major-Requirement-Changes-as-of-1_1_2026.pdf` — Scouting America's
  list of merit badge requirement changes effective Jan. 1, 2026, published
  11/14/2025, with the updated text of each changed requirement beside the 2025
  text it replaces. **Reach it through `scout-req` too.** It is the *major*
  changes, not the 2026 requirements book, and it covers **merit badges only** —
  no rank, no award — so it never licenses saying "everything else is
  unchanged", and says nothing about whether ranks changed.
- `references/guide-to-advancement-2025.pdf` — the Guide to Advancement 2025, the
  policy manual governing *how* advancement is administered (boards of review,
  procedures, roles). Use this for process and policy questions, via the
  `guide-to-advancement` skill.
- `references/EagleProjectWorkbook2023a.pdf` — the Eagle Scout Service Project
  Workbook, No. 512-927, revision 2023a: the four project forms and the
  instructions around them. **Reach it through the `eagle-req` skill, never with
  `pdftotext` or the Read tool's text path** (see above) — this PDF's text layer
  drops letters without saying so. It is February 2023 and reprints excerpts of
  the Guide; where the two overlap, the 2025 Guide governs.

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

It also holds the URLs of the troop's live data sources — the calendar feed and
the badge inventory sheet — which is why it is where a skill looks for one
rather than hard-coding it.  Both are read anonymously over plain HTTP, so both
have to stay link-shared; neither skill has any credentials to fall back on.

## Technology Preferences

- Prefer Ruby 3.4.5 (via asdf) for scripts.
- Use SQLite for any local data storage, via the `sqlite3` gem.
- Manage gems with Bundler and the repo-root `Gemfile`.
