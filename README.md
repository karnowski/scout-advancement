# Scout Advancement

Claude skills to help the troop Advancement Chair and Scoutmasters communicate and plan a Scouting America troop advancement program.

## Getting started

1. Install the dependencies: Ruby 3.4.5 (via asdf), gems via `bundle install`,
   and `poppler` for `pdftotext`/`pdftohtml` (`brew install poppler`).
2. Copy the troop settings template and fill it out for your troop:

   ```
   cp TROOP-SETTINGS.md.example TROOP-SETTINGS.md
   ```

   Edit `TROOP-SETTINGS.md` with your troop's number, location, calendar feed
   URL, patrols, and advancement conventions. `TROOP-SETTINGS.md` is gitignored,
   so a fork of this project won't accidentally commit another troop's details.
3. Drop the TroopMaster reports any skills need into `reports/` (also gitignored).

## Skills

### `guide-to-advancement`

Answers questions about *how* advancement is administered — boards of review,
Eagle Scout procedures, merit badge counseling, appeals, time extensions,
alternative requirements, advancement for members with special needs, and
unit/district/council roles.

Every answer comes from the text of the _Guide to Advancement 2025_
(`docs/guide-to-advancement-2025.pdf`), never from memory: the skill quotes the
supporting passage verbatim and cites the Guide's own section number, section
title, and printed page (e.g. *8.0.1.1 "Not a Retest or 'Examination'", printed
p. 55*).  It also preserves the Guide's distinction between **must** (mandated),
**should** (recommended), and **may** (optional), which is usually the point of
the question.  When the Guide doesn't cover something, the skill says so and
points to the local district or council advancement chair rather than guessing.

### `scout-req`

Looks up the official text of a rank, merit badge, or award requirement in
_Scouts BSA Requirements 2025_ (`docs/Scouts-BSA-Requirements-2025.pdf`) — *what*
a Scout must do, as distinct from the `guide-to-advancement` skill's *how* it is
administered.  It indexes all 9 ranks, 139 merit badges, and 26 awards, searches
requirement text, and quotes it verbatim with the printed page and the year.
It is the only thing in this repository that reads the requirements book; the
other skills call it rather than opening the PDF themselves.

Because the answer is only as good as the printing it came from, the skill is
built to be **loud about anything the 2025 book cannot answer**.  A merit badge
introduced, renamed, or revised after that printing gets a full-width banner and
a distinct exit status rather than a fluent, well-cited, wrong answer — which is
the only other thing that could happen, and is invisible once it reaches a Scout.
Badges the book has never heard of are caught automatically; badges that are in
the book but changed later are recorded by hand in
`.claude/skills/scout-req/data/beyond-2025.json`.

Because that check only helps if it actually gets run, it also comes in bulk: a
`check` command takes a whole list of names, says nothing at all about the ones
the book covers, and fails on the ones it does not.  `target-eagle` pipes every
merit badge in a report through it before writing a plan.

The parse checks itself against the book's own Merit Badge Library index before
anything is quoted.

### `troop-calendar`

Answers questions about the troop schedule — what's coming up, when the next
campout or court of honor is, what's on a given date — from the troop's
published calendar feed (see `TROOP-SETTINGS.md`).

It downloads the Google Calendar iCal feed, expands recurring events into concrete occurrences (resolving the many single-instance overrides the troop's calendar accumulates), and caches them in SQLite, re-syncing when the cache goes stale.

### `target-first-class`

Turns a TroopMaster **Target First Class** report — the dense grid of every
Scout working toward Scout, Tenderfoot, Second Class, and First Class — into an
advancement plan and a set of to-do lists.  The report says what is *done*; the
plan says what to *do*, in what order, and on which dates.

Most of the skill's value is in the three things the grid does not state: which
requirements carry a calendar clock that cannot be compressed (the Tenderfoot →
Second Class → First Class fitness chain), which Scouts have a pile of banked
work sitting behind one unearned rank, and whether the Scoutmaster conference and
board of review load actually fits in the meeting nights available.  It draws
real dates from `troop-calendar`, policy and citations from
`guide-to-advancement`, and requirement text from `scout-req`.

Plans are written to `plans/target-first-class-YYYY-MM-DD.md`, dated from the
report they read.

### `target-eagle`

Turns a TroopMaster **Target Eagle** report — the Scouts working toward Star,
Life, and Eagle — into an advancement plan and a set of to-do lists.  It reads
*two* reports together: the Target Eagle grid, which says how much active time,
service, and how many merit badge slots are left, and the matching **Partial
Merit Badges List**, which says *which* badges are in progress and exactly which
requirements are open.  The grid alone will tell you a Scout needs three more
merit badges; only the partials list tells you two of them are 98% done.

For this cohort the binding constraint is rarely meeting-night capacity.  It is
merit badges, service hours, the Eagle project, and the 18th birthday — so the
skill leads with who is running out of time, which requirements carry a
multi-week clock (Personal Management's 13-week budget, Personal Fitness's
12-week program, Camping's 20 nights), and which Scouts are one meeting away
from a rank that has to be awarded before the next rank's clocks can start.

Before any of that, it runs every merit badge named in the report through
`scout-req`, so a badge whose requirements changed after the 2025 printing stops
the plan instead of quietly shaping it.  Requirement text comes from `scout-req`
too, dates from `troop-calendar`, and policy from `guide-to-advancement`.

Plans are written to `plans/target-eagle-YYYY-MM-DD.md`, dated from the report
they read.
