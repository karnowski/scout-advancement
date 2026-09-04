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
   URL, badge inventory sheet URL, patrols, and advancement conventions.
   `TROOP-SETTINGS.md` is gitignored, so a fork of this project won't
   accidentally commit another troop's details.
3. Drop the TroopMaster reports any skills need into `reports/` (also gitignored).

## Troopmaster Reports

#### Custom Filters

First off, make sure to create or update two custom filters in TroopMaster:
- **Target First Class [date]** - Scouts with no rank or the Scout, Tenderfoot, or Second Class rank.  Does NOT include scouts in First Class.  This filter will be used for the "Target First Class" report.
- **Target Eagle [date]** - Scouts with First Class, Star, or Life rank.  This filter will be used for the "Target Eagle" report.

The "[date]" in the filter name is the date of when the filter was last updated.  Since custom filters in Troopmaster are basically just lists of specific scouts, they must be updated on rank-ups and scout additions.

## Base Reports

Then you run the following reports in TroopMaster and save them to the `reports/` directory:
- **Target First Class** - Use the "Filter - Target First Class [date]" to choose the correct scouts.  Save the report as `reports/target-first-class-[date].pdf`.
- **Target Eagle** - Use the "Filter - Target Eagle [date]" to choose the correct scouts.  Save the report as `reports/target-eagle-[date].pdf`.
- **Individual History** - The full per-Scout advancement record.  Save the report as `reports/IndividualHistoryReport-[date].pdf`.  It needs no custom filter; run it for whichever Scouts you are planning for, and the `import-individual-history` skill will merge each Scout into the database without disturbing anyone whose stored data is newer.


## Skills

### `guide-to-advancement`

Answers questions about *how* advancement is administered — boards of review,
Eagle Scout procedures, merit badge counseling, appeals, time extensions,
alternative requirements, advancement for members with special needs, and
unit/district/council roles.

Every answer comes from the text of the _Guide to Advancement 2025_
(`references/guide-to-advancement-2025.pdf`), never from memory: the skill quotes the
supporting passage verbatim and cites the Guide's own section number, section
title, and printed page (e.g. *8.0.1.1 "Not a Retest or 'Examination'", printed
p. 55*).  It also preserves the Guide's distinction between **must** (mandated),
**should** (recommended), and **may** (optional), which is usually the point of
the question.  When the Guide doesn't cover something, the skill says so and
points to the local district or council advancement chair rather than guessing.

### `scout-req`

Looks up the official text of a rank, merit badge, or award requirement — *what*
a Scout must do, as distinct from the `guide-to-advancement` skill's *how* it is
administered.  It reads two documents and never one alone:

- _Scouts BSA Requirements 2025_
  (`references/Scouts-BSA-Requirements-2025.pdf`), indexed down to all 9 ranks,
  139 merit badges, and 26 awards;
- _Major Requirement Changes as of 1/1/2026_
  (`references/Major-Requirement-Changes-as-of-1_1_2026.pdf`), Scouting
  America's change list published 11/14/2025.

**65 of those 139 merit badges changed effective Jan. 1, 2026**, so the book on
its own is now out of date for nearly half of them.  The change list carries the
updated text of every changed requirement, and a lookup prints it after the 2025
entry, each with the year and page it came from.  This is the only thing in the
repository that reads either PDF; the other skills call it rather than opening
them.

Because the answer is only as good as the printing it came from, the skill is
built to be **loud about anything it cannot answer**.  There are exactly three
outcomes: clean, changed-for-2026 (a flagged answer, with the new text), and a
full-width banner plus a distinct exit status for a badge neither document
covers.  What it never does is produce a fluent, well-cited, wrong answer —
which is the only other thing that could happen, and is invisible once it
reaches a Scout.  Badges the book has never heard of are caught automatically;
badges introduced, renamed, or discontinued since are recorded by hand in
`.claude/skills/scout-req/data/beyond-2025.json`.

Because that check only helps if it actually gets run, it also comes in bulk: a
`check` command takes a whole list of names and says nothing at all about the
ones that are clean.  `target-eagle` pipes every merit badge in a report through
it before writing a plan.

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
`scout-req`, so a badge that changed for 2026 is planned from the 2026 text and
one that neither document covers stops the plan instead of quietly shaping it.  Requirement text comes from `scout-req`
too, dates from `troop-calendar`, and policy from `guide-to-advancement`.

Plans are written to `plans/target-eagle-YYYY-MM-DD.md`, dated from the report
they read.

### `mbc`

Answers **"do we have a counselor for this badge, and who is it?"** from the
TroopMaster **MBC Grouped By Badge** report — the question that decides whether
a Scout can start a badge this month or has to wait for the district to find
someone.

It parses the report into SQLite, then answers lookups in both directions: who
counsels a badge, and what one counselor covers.  Because the report lists only
badges that *have* a counselor, it reads the full badge list from `scout-req` at
load time — that is what lets it tell "nobody in this troop counsels it" apart
from "that is not a merit badge," which are very different things to tell a
Scout.  `gaps --eagle` reports coverage of the 13 Eagle-required *slots*,
counting the OR-groups correctly.

The skill answers *who counsels*, never *what the requirements are*; requirement
text comes from `scout-req`.  A badge can have a current counselor and still be
one the 2025 printing cannot answer for.

### `eagle-req`

Answers questions about the **Eagle Scout service project** — what the proposal
has to show, what the project plan is for and who (nobody) approves it, which
fundraising needs a council application, what the report asks for, and who signs
what in which order — from the _Eagle Scout Service Project Workbook_, No.
512-927, revision 2023a (`references/EagleProjectWorkbook2023a.pdf`).

This is the most-mythologized requirement in Scouting: "you need 100 hours," "it
has to be construction," "the troop approves the plan," "you can't do it for a
business."  All of those are wrong, and the workbook says so in as many words —
so the skill quotes it, and cites the workbook's own page labels, the same way
the workbook cites itself ("page B of the fundraising application").

Getting there took some doing.  **This PDF's text layer is broken, and it fails
silently**: eight of its eleven embedded Arial fonts carry an incomplete
character map, so `pdftotext`, `pdftohtml`, and pdf-reader alike *delete*
letters rather than garbling them.  Eagle Scout requirement 5 comes out of all
of them as "W ile a i e Scout la evelo a give lea er i to ot er…" — still
shaped like prose, still quotable, and wrong.  The skill reconstructs the
missing letters from the glyph order the file's own character maps prove, and
`verify` re-derives that proof from the PDF on every run and extracts the
workbook a second time with the repair switched off, so the check reports what
the repair is actually worth rather than only that nothing looks wrong.

Because the workbook is February 2023 and reprints excerpts of the Guide to
Advancement, the skill treats those blocks as summaries rather than as the
policy: where the 2025 Guide and the 2023 workbook overlap, it reads
`guide-to-advancement` and says which one governs.

### `coh-shopping-list`

Turns a TroopMaster **Court Of Honor** report into a Scout Shop order: what the
troop already holds, and what has to be bought before the ceremony.  It reads
the report for what is being handed out and calls `badge-inventory` for what is
in the box.

The whole thing turns on the troop distributing on **two different clocks**.
Rank patches and position patches are awarded the day they are earned, so by the
time the report prints they are already on uniforms — those appear in the order
as a *restock*, against the stock bands the troop keeps (7–10 of each rank up to
First Class, 5–8 from Star up).  Merit badges, special awards, National Outdoor
Awards, and **both** rank pins are held for the ceremony, so those are counted
per Scout.  A rank in the report therefore means two pins to hand out, not a
patch to buy — and an order that gets this backwards is wrong in both directions
at once.

One line comes from neither the report's counts nor the sheet: a **merit badge
card** goes out with every badge, and the Scout Shop sells cards by the package
of 100, so the order carries whole packages rounded up against the report's
merit badge total.  Nobody counts the card drawer, so that figure is a ceiling
to subtract from rather than a measured shortfall, and packages are never added
into the count of single patches.

The inventory sheet counts patches of a retired design in a column apart from
`Count`, and the order keeps them apart too: an out-of-date patch is never in
the on-hand number and never reduces what to buy.  It is reported beside the
line it belongs to, with the sheet's own note on what is wrong with it, because
whether an older border is acceptable is the Advancement Chair's call to make.

Because a misparse of this report yields a slightly different order rather than
an obvious error, `verify` leans on the report's own Awards Summary: each
section's declared total, the summary's line items, and an independent re-tally
of the per-Scout detail pages all have to agree.  It also reports, per rank,
whether the inventory count was taken *after* the patches went out — a count
from before a Scout ranked up still includes a patch that has already left the
box.

Orders are written to `plans/coh-shopping-list-YYYY-MM-DD.md`, dated from the
report they read.

### `import-individual-history`

Reads a TroopMaster **Individual History** report — the most complete per-Scout
export TroopMaster produces — into a local SQLite database, one record per
Scout.  For each Scout it stores the ranks already earned, every requirement of
every rank *not* yet earned with its sign-off date, the merit badges earned, the
partials with their open requirements and counselor, camping/hiking/service
totals, special awards, and the full leadership history with dates.

It is the loading dock: it parses, verifies, and stores.  It never says what a
Scout should work on next and never quotes a requirement.  Asking what it stored
is `individual-history`; planning from the answers is
`generate-advancement-plan`.

Two things about it are worth knowing.  The report is a **table that only
coordinates can parse** — in the merit badge list a long name runs into its own
date with a single space between them, so `pdftotext -layout` merges the two and
the badge loses its date; the script uses `-bbox-layout` and rebuilds rows from
x/y positions.  And **freshness is tracked per Scout, not per file**: every
record carries the date printed on the report it came from, so importing an
older report fills in the Scouts it knows about and rewinds nobody.  `stale`
flags anyone whose data is too old to plan from.

Because a misparse of a grid this dense looks like a Scout who is behind rather
than like an error, `import` runs `verify` first and refuses to store anything
that fails it.

### `individual-history`

Answers **"what does the record actually say?"** from what
`import-individual-history` stored — for one Scout, or for everyone at once.  It
is the skill for a Scoutmaster conference, for a parent asking what their Scout
still needs, and for deciding who is ready for a board of review.

`show` prints a Scout's whole record and `needs` narrows it to what is unsigned
for their next rank.  `roster`, `who`, `badge`, and `partials` ask the same
questions across the troop — who still owes a position of responsibility, who
has a given badge, whose partials have gone idle.  It reads the database and
never opens a PDF.

Two of its answers are ones nobody wants to work out by hand.  **Eagle coverage**
is computed against the Eagle-required *slots* rather than from the report's own
star, because three slots are OR-groups (Emergency Preparedness *or* Lifesaving,
and so on) and because a badge the report never names carries no star at all.
And **position-of-responsibility tenure** counts only service since the Scout
earned the rank they hold now, with overlapping terms merged: a Scout who held
Bugler and Patrol Leader over the same six months served six months, not twelve.

The slot list has **13 entries, not the 14 printed at Eagle requirement 3**: this
troop does not count Citizenship in Society as filling an Eagle-required slot,
though it still counts toward the 21 badges Eagle asks for.  That is a decision
of the troop's rather than a reading of the book, it matches what TroopMaster
itself computes, and the `individual-history` skill sets out the evidence and
keeps TroopMaster's own figure on screen as a cross-check.

Like the importer it reports rather than plans — it says what is signed off and
how many months have been served, and leaves what to do about it to
`generate-advancement-plan`.

### `generate-advancement-plan`

Turns one Scout's stored record into **a plan**: what to work on, in what order,
and by which date.  The record says what is done; this says what to do about it,
across rank requirements, merit badges, and the position of responsibility.  It
is the skill for a Scoutmaster conference, for a parent asking "what's next",
and for deciding where a Saturday is best spent.

Its whole design is that **there are three kinds of clock and they are not
interchangeable**.  *Elapsed* time — six months active as a Star Scout, months
served in a position — passes whether or not anyone is working on it, so those
dates come out of the record and are facts.  *Work-start* clocks — Tenderfoot's
30-day fitness log, Personal Management's 13 weeks, Family Life's 90 days —
measure 30 days of *tracked work*, so they start when the Scout starts and never
from a date already in the record.  And *opportunity* items — Camping's 20
nights, Citizenship in the Community's 8 volunteer hours, Personal Fitness's
exams — are not a span of calendar at all: they need an event or an appointment,
so the plan takes them to `troop-calendar` rather than inventing a date.  A plan
that conflates the three is specific, confident, and wrong.

Three findings come out of it more often than any others.  **Work banked above
an unearned rank** — ranks must be earned in sequence, so a Scout can have
thirty-odd First Class requirements signed and be stuck behind Tenderfoot, and a
handful of cheap items converts all of it.  **A position of responsibility with
no clock running at all**, which is a much larger problem than one that has not
finished yet, and usually fixable the same week.  And **the fitness chain's
cumulative start-by**: First Class 8a is twelve weeks out, not four, because
each link needs the one above it finished.

It plans for one Scout at a time, and it plans only — what the record *says* is
`individual-history`, so every line of a plan can be checked against it.  Before
writing anything it runs every badge name through `scout-req`, because a
TroopMaster report is exactly where a badge whose requirements changed in 2026
enters unannounced.

### `troop-advancement-plan`

Answers **"what do we actually do at the next few meetings and activities?"**
for the whole troop, from the same stored records.  It is the skill for the
Scoutmaster and Advancement Chair sitting down to schedule a quarter, and it is
deliberately not thirty-eight individual plans stapled together: it stops at the
cohort, and hands any Scout who needs a real plan to `generate-advancement-plan`.

Its central idea is the **program theme**.  Every open requirement in the troop
is sorted onto the kind of session that could sign it — a meeting night, a
campout, an outing that needs a pool or an orienteering course, a service
project — and the tally is reported two ways at once, because the two answer
different questions.  A cooking campout signs Tenderfoot 2a for one Scout,
Second Class 2e for another, and First Class 2b for a third, and for a new Scout
it signs work at all three ranks; that total is what the evening is *worth*.
Only the sign-offs at each Scout's own working rank convert to a rank now; that
subset is what it *advances*, and it is the number that decides which court of
honor the session shows up in.

Three more things fall out of the cohort view that no individual plan asks.
**A clock is a group decision, not sixty to-do lines** — nineteen Scouts share
one start-by date for Personal Management's thirteen weeks, which is one
announcement at one meeting.  **The conference and board load is a capacity
question**, counted against the troop's per-meeting cap and the meeting nights
actually on the calendar, with Scout rank's missing board of review and Eagle's
non-troop board both handled apart.  And **a badge idle for eighteen months
across a dozen Scouts is a troop finding, not a Scout one**: a group started it
together and stopped, and someone has to decide whether to finish it or write it
off.

Every per-Scout number it prints is read back out of `generate-advancement-plan`
rather than recomputed, so the troop plan and the individual plans cannot
disagree.  `verify` checks that, checks that every requirement in the data is
claimed by exactly one of its tables, and refuses to run if the planning skill's
own verify fails.

### `badge-inventory`

Answers **"do we have one, and how many?"** — rank patches and rank pins,
position-of-responsibility patches, awards, and merit badge patches — from the
troop's badge inventory Google Sheet.  This is the question that decides whether
a Scout gets their patch at the next court of honor or whether someone has to
place a Scout Shop order first.

It downloads every tab of the sheet as CSV and caches the rows in SQLite,
re-syncing when the cache is over six hours old.  The sheet is shared as
"anyone with the link can view", so there are no Google credentials involved.

The interesting part is that **there are two dates and only one of them means
the number is right**: when the script last downloaded the sheet, and when a
human last opened the box and counted.  A count synced thirty seconds ago that
was last physically counted in January is still a January count, so every
answer prints the check date beside the number, and `stale` lists the rows
nobody has recounted lately.

Like `mbc`, it reconciles its merit badge tab against `scout-req` — the sheet
runs ahead of the 2025 printing by three badges — and it reports inventory
only.  What a badge requires still comes from `scout-req`, and who counsels it
from `mbc`.
