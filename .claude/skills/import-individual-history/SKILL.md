---
name: import-individual-history
description: Read a TroopMaster "Individual History" report into a local database — every Scout's ranks, requirement sign-offs, merit badges, partials, awards, and leadership — so advancement plans are built from stored data rather than by re-reading a PDF.
---

# Import Individual History

Turn a TroopMaster **Individual History** report into rows in a local SQLite
database, one record per Scout, each stamped with the date of the report it came
from.

This skill is the *loading dock*.  It parses, verifies, and stores — and stops
there.  It never decides what a Scout should work on next, never quotes a
requirement, and never writes a plan.  Answering questions about what it stored
is `individual-history`; planning from those answers is
`generate-advancement-plan`.

The Individual History report is the most complete per-Scout export TroopMaster
produces.  For every Scout it prints the ranks already earned, **every
requirement of every rank not yet earned** with its sign-off date or `__/__/__`,
the merit badges earned, the partials with their open requirements, counselor
and remarks, camping/hiking/service totals, special awards, National Outdoor
Award segments, training courses, Order of the Arrow membership, and the full
leadership history with dates.  That is enough to plan from without going back
to the PDF.

It exports at any scope — one patrol, or the whole troop.  The troop's current
export is all 38 Scouts across 92 pages, and the whole-troop run is what turns
up the shapes a small one never shows: Palms past the third, a Scout who joined
last month and has no ranks or badges at all, a Scout holding four positions at
once.

## Tool

`scripts/individual_history.rb` parses the report and stores it in
`.cache/individual-history.db`.  It needs the repo's gems and `pdftotext`; if a
command reports a missing gem run `bundle install` from the repository root, and
if `pdftotext` is missing run `brew install poppler`.

```
ruby scripts/individual_history.rb verify [REPORT.pdf]     # cross-check the parse — run this first
ruby scripts/individual_history.rb import [REPORT.pdf]     # verify, then store
ruby scripts/individual_history.rb list                    # who is stored, and how old each one's data is
ruby scripts/individual_history.rb stale [--days N]        # whose data is too old to plan from
ruby scripts/individual_history.rb badges [REPORT.pdf]     # badge names, one per line, for req.rb check
ruby scripts/individual_history.rb notes  [REPORT.pdf]     # only what is worth knowing before planning
```

With no `REPORT.pdf` the newest `IndividualHistory*.pdf` in `reports/` is used,
which is normally what you want — drop the export there and run `import`.

`list` and `stale` are about the *import* — who is stored and how old each
one's data is.  **Reading what was stored is the `individual-history` skill**,
not this one: one Scout's record, what a rank still needs, Eagle-required
coverage, position-of-responsibility tenure, and the troop-wide roll-ups.

    ruby ../individual-history/scripts/history.rb show "Rivera, Sam"
    ruby ../individual-history/scripts/history.rb roster

`show` and `json` used to live here; running either now prints where they went.

## Import it, don't read the PDF

Everything downstream reads the database, not the report.  Two reasons, and both
have teeth:

- **The report is a table that only coordinates can parse.**  Under plain
  `pdftotext -layout` a long badge name runs into its own date with a single
  space between them, so `Soil and Water Conservation 02/28/26` is
  indistinguishable from a name containing spaces.  The script uses
  `-bbox-layout` and rebuilds rows from x/y positions.  Reading the extracted
  text by eye reproduces exactly the mistake the script exists to avoid.
- **A misparse looks like a Scout who is behind, not like an error.**  There is
  no visual tell.  `verify` is the tell, and `import` refuses to store anything
  that fails it.

## Then check the badge names

A TroopMaster report is exactly where a badge the 2025 requirements book does
not carry enters unannounced, and where a badge whose requirements changed for
2026 goes unflagged.  Before planning from an import:

```
ruby scripts/individual_history.rb badges | ruby ../scout-req/scripts/req.rb check
```

Exit 3 means at least one badge is in **neither** the 2025 printing nor the 2026
change list — stop and get its requirements from scouting.org.  A badge merely
*changed* for 2026 is not an error, but the 2025 text is out of date for it, so
`req.rb show NAME` before planning any work on it.  On the troop's current
whole-troop report 45 of the 95 badges named have changed for 2026, so this is
not a rare case — it is nearly half of them.

## Freshness is per Scout

Every stored Scout carries the date printed on the report that supplied them,
and `list` shows how old that is.  This matters because reports get run for one
patrol as often as for the whole troop: the newest file is not the newest data
for everyone.

So `import` compares dates **per Scout**.  A Scout whose stored data came from a
*newer* report is left alone and reported as skipped; `--force` overrides.  That
makes importing an older report safe — it fills in the Scouts it knows about
better than nothing, and rewinds nobody.

`stale` flags Scouts whose data is older than 30 days.  An advancement plan
built on a months-old report will confidently list work the Scout has already
finished, so check `stale` before a planning run and re-export if it complains.

## What the stored data means

These are facts about the rows, and they hold wherever the rows are read —
`individual-history` repeats the ones its answers turn on.

- **`__/__/__` is not missing data.**  It is the report saying a requirement is
  printed and not signed off.  The database keeps that distinct from a
  requirement it never saw: `signed` is 0 with a NULL `completed_on`, and a
  requirement absent from the table is absent from the rank.  Every plan turns
  on that difference.
- **A rank with no requirement rows has been earned**, not skipped.  The report
  prints requirement blocks only for ranks the Scout has *not* earned; earned
  ranks appear as one line each under Completed Ranks.
- **`_______________ MB` is an unfilled merit badge slot**, not a requirement
  with a strange name.  In the data they are
  `kind = 'badge_slot'` with a NULL `badge`, and they are reported as "N more
  merit badges".
- **`rank_blocks.eagle_mb_remaining` is TroopMaster's count, not ours.**  Where
  a rank still wants Eagle-required badges the report heads its block
  `Star (2 Eagle MB remaining)`, and that number is stored as printed.  It is
  NULL for every block the report did not annotate.  Do not treat a NULL as
  zero, and do not recompute it here — Eagle-required coverage is
  `individual-history`'s answer, from `EAGLE_SLOTS`.
- **Palms repeat with an ordinal.**  After Bronze, Gold and Silver the cycle
  starts again as `2nd Bronze Palm`, and the troop's report reaches
  `3rd Gold Palm`.  Each is its own block with its own requirements; `rank` in
  the data is the heading verbatim, and `block_order` is what puts them in the
  order they are awarded.
- **`outdoor_awards` and `training_courses` are not `special_awards`.**  The
  report keeps all three apart and so does the database: the "NOA Camping Gold"
  under Special Awards is the award, while "Camping" under National Outdoor
  Awards is the segment behind it.
- **A partial's `remarks` are the Advancement Chair's own notes**, not part of
  `open_reqts`.  They are free text — "Completed one ride for 6Bd at
  WinterBlast 26" — and often say something the percentage does not.
- **`*` after a badge name means Eagle-required.**  It is stored as
  `eagle_required` and stripped from the name.
- **`#` is stored verbatim and still not interpreted, but the evidence has
  narrowed.**  The page legend defines `#` only for leadership ("Position not
  credited toward rank"), and that meaning is stored as `credited = 0`.  On a
  badge the legend says nothing — yet across all 38 Scouts on the whole-troop
  report **Citizenship in Society is the only badge that ever carries it**, and
  the only Citizenship badge that never carries `*`.  TroopMaster's own
  Eagle-remaining counts reproduce only if CiS is left out of the Eagle-required
  list, so `#` on a badge reads as "not counted toward Eagle-required" — the
  same sense the legend gives it for a position.  That is inference, not the
  legend, so the marker is still stored raw and reported as a note.  See
  `individual-history` for what it does to an Eagle answer.
- **Partials carry a requirement *year*** (`Personal Management* (2019)`) — the
  edition of the requirements the Scout started under.  Say which year when
  discussing a partial; it is often not the current one.
- **`Participation` and `Scoutmaster Conference` in a Palm block are annotated
  `(discontinued 2024)`.**  The annotation is stored in `note`.
  Report it rather than treating those as work to be done.

## Requirement text comes from elsewhere

This skill stores the report's own short labels — `4c. Tell How to Prevent
Injury`, `Position of Responsibility`.  **Those are TroopMaster's abbreviations,
not the requirements.**  They are far too short to plan from and are not
maintained against the book.

The text that governs comes from `scout-req`:

```
ruby ../scout-req/scripts/req.rb show "First Class"
ruby ../scout-req/scripts/req.rb show "Personal Management"
```

Likewise, who counsels a badge comes from `mbc`, and how advancement is
administered comes from `guide-to-advancement`.  Never quote a label from this
database as though it were a requirement.

## Privacy

**This repository is public and this report is a roster of minors** — names,
email addresses, phone numbers, dates of birth, and BSA member IDs.

The database lives in this skill's `.cache/`, which `.gitignore` covers, and the
report lives in `reports/`, which it also covers.  Nothing from either belongs
in a tracked file, a commit message, a branch name, or a PR description.  Names
are fine in a session and in answers to the Advancement Chair; they never reach
git.  The names in this file are invented.

## Facts about the report the script depends on

Each of these was established by getting it wrong first.  **Read them before
changing the parser** — the code shows what is done, not the alternative that
was tried and silently produced garbage.

- **`-bbox-layout`, not `-layout`, and the reason is measured.**  In the Merit
  Badges list a long name runs up against its date with a *single* space — the
  same as the space inside the name (`Soil and Water Conservation 02/28/26`,
  `Environmental Science* 11/09/24`).  Splitting on runs of spaces merges the
  two and the badge loses its date.  Only coordinates separate them.
- **Every table cell is its own `<line>`, and a row is the set of lines sharing
  a `yMin`.**  TroopMaster draws the report column by column, so poppler emits
  the name column and the date column as separate blocks — `Art` and its
  `08/29/23` never appear in the same line element.  Reading lines top to bottom
  interleaves the columns; rows have to be rebuilt by clustering on y and
  sorting by x.
- **Except for a value TroopMaster shrank to fit, whose `yMin` is *lower* than
  its own label's.**  A Scout holding four positions gets a `Position:` value
  set at 5.5pt rather than 9.25pt, reported as starting 3pt below the
  `Position:` beside it.  Clustering on `yMin` alone leaves it in a row of its
  own that nothing claims, so a row also takes in a line whose band sits
  *inside* the band already open — containment, not proximity.
- **A block heading is not always just the rank.**  Where a rank still wants
  Eagle-required badges the heading carries TroopMaster's count of them,
  `Star (2 Eagle MB remaining)`; past three Palms it carries an ordinal,
  `2nd Bronze Palm`.  Matching headings against a fixed list of names misses
  both **silently**: the rows below are read as more of the previous block, and
  the heading itself — a lone cell with no date — is filed as an annotation on
  the requirement above it.  The parenthetical is matched strictly, so a form
  nobody has seen yet fails rather than being read as part of the rank name.
- **A partial carries `Remarks:` as well as `Open Reqts:`, and either can
  wrap.**  A wrapped line is unlabelled, so the parser has to remember which
  field it continues.  Assuming it is always `Open Reqts:` appends the
  Advancement Chair's prose to the list of open requirements.
- **`Position:` is a comma-separated list** when a Scout holds more than one
  job.  Compared as a single string it never matches the Leadership section.
- **TroopMaster prints badge names short** — "Fish and Wildlife" for the book's
  "Fish and Wildlife Management" — so the book match falls back to an
  unambiguous containment match, as `req.rb resolve` does.  Without it the
  troop's own abbreviations are announced as badges the book does not carry.
- **Column x-origins differ from Scout to Scout.**  A Scout with long badge
  names gets wider columns.  Nothing may hard-code an x.  Cells are paired left
  to right — label, then the next cell that looks like a date — which is why a
  missing value (a Scout with no `Position:`, or no date of birth) shifts
  nothing: the cell is simply absent from the row.
- **A long label and its date can still land in one cell** even under
  `-bbox-layout`, so `Row#pairs` splits a trailing date back off.  The guard is
  that the text before it must not end in `-`, or a Leadership cell reading
  `04/22/25 - 10/22/25` gets torn into a label and a date.
- **Only ranks the Scout has NOT earned get a requirement block**, so an empty
  requirement set for a rank means *earned*.  `verify` asserts the completed
  list and the printed blocks never overlap, and that every unearned rank on the
  ladder has a block.
- **A parenthesised line under a requirement is an annotation on the
  requirement above it, in the same column.**  The Palm block prints
  `(discontinued 2024)` on its own row at the left column's x under
  `Participation`, and again at the right column's x under `Scoutmaster
  Conference`.  It is attached by x; by y alone it looks like a row of its own
  with a missing date.
- **Sections are optional and the last one can simply stop.**  A Scout with no
  leadership history has no Leadership section at all and the report ends
  mid-page.  A parser that expects a fixed section order to terminate reads the
  next Scout's header as this one's data.
- **The report carries its own tally, and it is the one real cross-check.**
  Each Scout's badge list is headed `Merit Badges : N`.  `verify` checks N
  against the rows parsed, and independently that every badge named in a
  Star/Life/Eagle slot appears in that list *with the same date* — the two are
  printed from the same data by different code paths, so a slipped column
  disagrees.
- **A Scout who has just joined has none of it.**  Blank `Rank:`, no Completed
  Ranks, and — the one that bites — **no Merit Badges section at all**, not a
  heading reading zero.  So a missing tally is a fact about the Scout unless
  badges were parsed anyway, which would mean the heading was missed.  Both are
  reported as notes; five Scouts on the current report have no badges yet.
- **Beyond the usual sections the report also prints Order of the Arrow,
  National Outdoor Awards and Training Courses**, each for the handful of Scouts
  who have any.  Every OA field is printed whether or not it has a value, so an
  empty one is a label with nothing after it.
- **Freshness is the date printed on the report**, not the file's mtime and not
  the filename.  It is printed top-left of each Scout's first page.

`verify` also insists every cell on every page is claimed by some section, that
completed ranks are a prefix of the ladder and agree with the header, that no
date is after the report date, that a badge is never both earned and partial,
and that each continuation page names a Scout the report actually contains.
Badges the 2025 book does not carry, uninterpreted `#` markers, absent dates of
birth, and missing leadership are reported as **notes**, not failures — each is
a true fact about the troop rather than a parse error.
