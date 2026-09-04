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
- `.claude/skills/import-activities-history/` — the other importer, and the only
  one whose rows are *dated quantities* rather than sign-offs: a TroopMaster
  "Individual Participation" report, one row per activity, each carrying the
  service hours, conservation hours, camping nights, or hiking miles it was
  worth.  It is what makes "this Scout owes three more service hours, one of
  them conservation" sayable at all — the Individual History report knows only
  that the requirement is unsigned.  It stores and it sums; it decides nothing,
  because the rank date the hours must follow lives in `individual-history` and
  the six-hour threshold lives in the book.  Its cache keys on the same BSA ID,
  so the two join.
- `.claude/skills/individual-history/` — answers questions about what that
  database holds, for one Scout or across the troop: what a rank still needs,
  Eagle-required slot coverage, position-of-responsibility tenure, idle
  partials, and the awards, National Outdoor Award segments, training courses
  and Order of the Arrow standing the report also carries.  It reads; it does
  not plan.
- `.claude/skills/generate-advancement-plan/` — turns one Scout's stored record
  into a plan: what to work on, in what order, and by which date, across rank
  requirements, merit badges, and the position of responsibility.  It plans; it
  does not report, and it does **one Scout at a time** — cohort work, batch
  sessions, and meeting-night throughput are deliberately not here.
- `.claude/skills/troop-advancement-plan/` — the cohort half of that: what the
  troop does at its next few meetings and activities.  It sorts every open
  requirement onto the kind of session that could sign it, rolls the clocks up
  by clock rather than by Scout, counts the conference and board load against
  meeting-night capacity, and names the handful of Scouts who need an adult.  It
  plans for the troop, never for a Scout; every per-Scout number it prints is
  read back out of `generate-advancement-plan`.
- `.claude/agents/advancement-plan.md` — the only agent in the repo, and the
  only thing here that is not a skill.  It wraps `generate-advancement-plan` for
  one named Scout end to end in its own context, so a patrol's worth of plans
  can be produced by launching several at once.  **That is parallel invocation,
  not a cohort analysis** — each copy still plans for exactly one Scout, and the
  troop-level question stays with `troop-advancement-plan`.  Three of its rules
  exist only because copies run concurrently: it touches only its own Scout's
  file, it never syncs a cache or re-imports a report (the launching session does
  that once, up front, because `calendar.rb` re-syncs itself whenever its cache
  is over six hours old), and it stops and reports rather than guessing past an
  ambiguous name, a Scout who has left the troop, or a failed `verify`.
- `reports/` — where to drop the TroopMaster PDFs a skill is asked to read.
  Gitignored; look here first when a skill needs a report and none was named.
- `plans/` — generated advancement plans, gitignored.  Named
  `<skill>-YYYY-MM-DD.md` (`coh-shopping-list-2026-08-17.md`), dated from the
  report they read, with an optional `-SCOPE` suffix when a run covers a subset
  rather than the whole report
  (`target-first-class-2026-08-01-seals.md` is the Seals patrol).  Two runs of
  the same scope on the same report overwrite; don't invent `-backup` names.
  `generate-advancement-plan` names its per-Scout plans
  `advancement-plan-{lastname}-{firstname}-YYYY-MM-DD.md`, lowercased, still
  dated from the report the record came from rather than from today, and
  `troop-advancement-plan` names its own
  `troop-advancement-plan-YYYY-MM-DD.md`, dated the same way.

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

Seven of the fourteen skills also need **`pdftotext`**, and `scout-req` additionally
needs **`pdftohtml`** — the latter for `req.rb`; the sibling `changes.rb` needs
only `pdftotext`, plus the `pdf-reader` gem for the table's drawn borders.
`activities.rb` uses the same gem for a third reason again — the Individual
Participation report prints no date of its own, so its report date comes from
the PDF's `CreationDate`.  Both tools come from poppler, and neither is a gem,
so `bundle install` alone leaves a fresh clone unable to run them:

    brew install poppler

`troop-calendar`, `eagle-req`, `badge-inventory`, `individual-history`,
`generate-advancement-plan`, and `troop-advancement-plan` need neither.  `eagle-req`
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
`scout-req`, which has one per document it reads, `individual-history`, whose
script reads the database `import-individual-history` writes rather than a
document of its own, `generate-advancement-plan`, whose script opens neither and
reads its record back out of `individual-history`, and `troop-advancement-plan`,
whose script reads `generate-advancement-plan`'s own analysis back out of it,
one Scout at a time:

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
- **`activities.rb`** (import-activities-history) — rebuilds the Individual
  Participation report's activity table from `pdftotext -bbox-layout` and stores
  it in `.cache/activities-history.db`.  Four things about it are wrong if
  reinvented.  **The Type column is separated from the Event Title by nothing
  but the words' own x** — a title runs into its type with a single space
  (`Soil & Water Conservation MB MB Program`), so `-layout` cannot tell the two
  apart and gets 12 of the current report's 1086 rows wrong, each one a
  plausible activity filed under the wrong heading; words are bucketed against
  column origins read off the table's own header row.  **The page header is a
  date range and starts with a date**, so a row filter keyed on "starts with a
  date" swallows the legend on all 91 pages; activity rows must also sit below
  the table header.  **The `# / Percent` block is not positionally readable** —
  a zero denominator prints `0 /` with nothing after it — so it is skipped
  deliberately and `verify` re-derives it from `count / offered` as a guard on
  that pairing instead.  And **the report's date range is a filter, not a
  Scout's history**: hours before it are simply absent, which reads as a Scout
  who owes more service than they do, so the window is stored and `hours
  --since` **refuses** a date before it rather than answering short.  The
  amount's unit is per type and the report declares it (`Camping # / Nights`,
  `Serv Proj # / Hours`, `Hiking # / Miles`), the `+`/`#` markers are pitch-tent
  and cabin nights and matter to Camping req. 9a, and the `of N` denominator is
  **opportunities offered to that Scout since they joined**, not a troop-wide
  event count.  It sums; it applies no threshold.
- **`plan.rb`** (generate-advancement-plan) — the dated arithmetic behind one
  Scout's plan.  It opens neither a PDF nor the database: **the record comes
  from `history.rb json`**, so the plan and the report cannot describe different
  Scouts, and name matching and freshness are the reading skill's.  Its whole
  design is that **there are three kinds of clock and they are not
  interchangeable.**  *Elapsed* — active participation, POR tenure — is calendar
  time that passes whether or not anyone is working on it, so those dates come
  out of the record and are facts.  *Work-start* — Tenderfoot 6b/6c, Second
  Class 7a, First Class 8a, Personal Management 2, Personal Fitness 7/8, Family
  Life 3 — measures 30 days of *tracked work*, so it runs from `--start` and
  never from a date in the record: a Scout whose 6a was signed six months ago has
  not thereby banked 30 days of 6b tracking.  *Opportunity* — Camping's 20
  nights, Citizenship in the Community's 8 hours, Personal Fitness's exams — is
  not a span of calendar at all, and `--by` deliberately prints no date for it,
  because inventing one is the specific error it exists to avoid.  Two further
  things are wrong if reinvented: the fitness chain's start-by is **cumulative**,
  since each link needs the one above it finished, and **a filled merit badge
  slot is not a signed rank requirement** — counting them together makes every
  Scout with badges toward Eagle look as though they had banked rank work.  Its
  `verify` checks no parse, because there is none; it checks that every match key
  still resolves and that its copies of `EAGLE_SLOTS` and the POR tenure
  algorithm still agree with what `individual-history` prints, Scout by Scout.
- **`troop.rb`** (troop-advancement-plan) — the cohort arithmetic, and the only
  script in the repo whose input is another skill's *analysis* rather than a
  document or the database.  It runs `plan.rb json` once per Scout, four at a
  time, so the troop plan and the individual plans are provably the same
  analysis; the sole derivation it makes for itself is which requirements are
  open at a rank, because themes key off `req_id` and `plan.rb json` prints
  labels, and `verify` compares that count against `plan.rb`'s own Scout by
  Scout.  Three things about it are wrong if reinvented.  **A theme spans every
  unearned rank, not just the working one** — one cooking campout signs
  Tenderfoot 2a, Second Class 2e and First Class 2b at once, so counting only
  the working rank halves what an activity is worth, while counting everything
  and calling it advancement overstates what a court of honor will show; both
  figures are printed because they answer different questions.  **The closing
  three are not a batch opportunity** — Scout Spirit, the conference and the
  board are open for nearly every Scout, so a plain frequency count of open
  requirements returns them at the top and says nothing; `CLOSING` keeps them
  out of `THEMES` and feeds the load count instead.  And **the elapsed and
  project requirements stay in the count of what a Scout has left but out of the
  themes** — a Scout whose position of responsibility is still running is not
  ready for a board, and calling them ready is the one mistake that number must
  not make.
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
depends on"** for the six TroopMaster skills, `scout-req` (which has one such
section per document), `eagle-req`, `badge-inventory`, `individual-history`
(whose source is the database rather than a document),
`generate-advancement-plan` (whose source is `individual-history`), and
`troop-advancement-plan` (whose source is `generate-advancement-plan`), and in
**header and inline comments** in `gta.rb` and `calendar.rb`.  `req.rb`,
`changes.rb`, `eagle.rb`, `inventory.rb`, `coh.rb`, `individual_history.rb`,
`activities.rb`, `history.rb`, `plan.rb`, and `troop.rb` each carry a second
copy in their own header, next to the code the facts constrain.

**Read them before changing a parser** — or, for `history.rb`, `plan.rb`, and
`troop.rb`, before changing what an answer is computed from. Each was
established by getting it wrong first, and none is recoverable by reading the
code alone — the code
shows what is done, not the alternative that was tried and silently produced
garbage.

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
  `activities.rb` has the richest tally of any of them, and needs it, because a
  misassigned activity row is an entirely ordinary-looking one: each Scout's
  rows are followed by a `# / Amount` block declaring a count *and* a summed
  amount for all 28 activity types, and then a `# / Total` block — 2128 declared
  figures against 1086 rows on the current report, every one re-derived and
  compared.  On top of that it insists every scrap of text on every page is
  claimed, that each Scout's summary covers every type the report declared for
  them (the only guard against a section migrating between Scouts, since
  continuation pages carry no name), that every activity date falls inside the
  report's own window, and that nobody attended more events of a type than were
  offered to them.  A new activity level, an unlisted marker, a negative amount,
  and a filename that disagrees with the PDF's generation date are notes.
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
  true fact about the troop rather than a parse error.  `plan.rb` is the one
  `verify` that checks no parse at all, because its input arrives already
  verified: what goes wrong there is silent **disablement**, so it checks that
  every badge name in its tables still resolves against `req.rb list --kind
  badge`, that every requirement label and fitness-chain link still appears in
  the imported data, and that its copies of `EAGLE_SLOTS` and the POR tenure
  algorithm still agree with what `individual-history` prints for every Scout.
  A renamed badge or a table edited in one copy and not the other otherwise
  leaves a plan that reads perfectly and has quietly stopped applying a rule.
  `troop.rb` is the same case one layer up, and it checks three things: it runs
  `plan.rb verify` first and fails if that fails, since every per-Scout number
  it prints comes from there; it asserts that **every requirement in the
  imported data is claimed by exactly one** of `THEMES`, `CLOSING`, and
  `INDIVIDUAL_LABELS`, in both directions, because a requirement TroopMaster
  renumbers otherwise drops out of its theme in silence and a theme that has
  quietly stopped counting anything reads exactly like a theme nobody needs; and
  it compares its one local derivation — the count of open requirements at each
  Scout's working rank — against `plan.rb`'s own, Scout by Scout.  A rank nobody
  is working on carries no rows at all, so that case is a note rather than a
  failure.
- **The `pdftotext` invocations are measured, not preferences** — `-bbox` for the
  grids, `-layout` for the partials list and the MBC report, plain `pdftotext`
  rather than the `pdf-reader` gem for the Guide, `pdftohtml -xml` alongside
  plain `pdftotext` for the requirements book, and `-bbox-layout` for the 2026
  change table, the Individual History report, and the Individual Participation
  report, whose columns only coordinates can separate.  Each is justified where
  it is used.  Do not swap
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

`troop-advancement-plan` adds no badge check of its own: its SKILL.md routes the
whole-troop check back through `individual_history.rb badges | req.rb check`,
because at troop scale the question is already answered for every badge in the
data and a per-Scout loop would only ask it 38 times.  Exit 3 there means no
badge session goes on the calendar for the badges it names — a session sends a
dozen Scouts to do the same wrong work at once.

`plan.rb` pipes its own `names` through `req.rb check` for that same reason, one
Scout at a time, and it is the last place the check can catch anything: a plan is
what actually sends a Scout to do months of work.  Exit 3 there stops the plan —
the badge is named, the banner is quoted, and no work is assigned on it.

`mbc.rb` and `inventory.rb` are the other consumers, and both use `req.rb list
--kind badge` rather than `check` — they need the *whole* badge list, because
"we have no counselor for that badge" / "we hold no patches for that badge" and
"that is not a badge" are different answers, and only the book can tell them
apart. Neither reports requirement text, so neither propagates exit 3; each
prints a note on a badge the 2025 printing does not carry and says to get the
requirements from scouting.org.

The Ruby tables that name requirements — `RANKS` in `tfc.rb`, `CLOCKS`,
`BLOCKS`, and `BADGE_PREREQS` in `te.rb`, `EAGLE_SLOTS` in `mbc.rb`,
`RANK_LADDER` and `PALM_METALS` in `individual_history.rb`, `EAGLE_SLOTS` and
`POR_MONTHS` in `history.rb`, and `EAGLE_SLOTS`, `POR_MONTHS`, `ACTIVE_MONTHS`,
`FITNESS_CHAIN`, `CLOCKS`, and `BADGE_PREREQS` in `plan.rb`, and `THEMES`,
`CLOSING`, and `INDIVIDUAL_LABELS` in `troop.rb` — are **match keys, not a
second copy of the book.**  The three `EAGLE_SLOTS` tables are the one
place the repo deliberately *departs* from the book rather than abbreviating it,
and the reason is written out at `history.rb` above.  Two guards keep them in
step, and neither covers all three: `plan.rb verify` compares its copy against
the slot labels `history.rb eagle` prints, and `mbc.rb verify` compares its own
against the stars on the MBC report.  Nothing checks `history.rb`'s against
`mbc.rb`'s directly, so **run both verifies after touching any of them.** They
exist so a
parser can identify a column, or find the Scouts on a clock. Their labels are far
too short to plan from and are not maintained against the book; the text that
governs comes from `scout-req`. Do not quote one into a plan, and do not delete
them either — the parsers do not work without them.

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
