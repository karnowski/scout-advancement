---
name: badge-inventory
description: Answer how many rank patches, pins, position patches, awards, and merit badge patches the troop has on hand, from the troop's badge inventory spreadsheet.
---

# Badge inventory

Answer **"do we have one, and how many?"** from the troop's own badge inventory
Google Sheet — rank patches and rank pins, position-of-responsibility patches,
awards, and merit badge patches.

This is the question that decides whether the Advancement Chair can hand a Scout
their patch at the next court of honor or has to place a Scout Shop order first.
It is a *supply* question, not an advancement question: this skill never says
what a Scout has earned or what a badge requires, only what is in the box.

## Tool

`scripts/inventory.rb` downloads every tab of the sheet as CSV and caches the
rows in SQLite under `.cache/inventory.db`.  It syncs automatically when the
cache is missing or more than six hours old, so normally you can go straight to
a query command.  It needs the repo's gems; if a command reports a missing gem,
run `bundle install` from the repository root.

```
ruby scripts/inventory.rb verify                      # cross-check the parse — run this first
ruby scripts/inventory.rb count NAME...               # how many do we have
ruby scripts/inventory.rb list [--category NAME] [--section N]
ruby scripts/inventory.rb low [--at N]                # at or below N (default 0)
ruby scripts/inventory.rb stale [--days N]            # not counted lately (default 90)
ruby scripts/inventory.rb outdated                    # retired designs, never in a count
ruby scripts/inventory.rb sync [--force]
ruby scripts/inventory.rb info
```

- `count` matches on a folded form of the name, so "life adult pins" finds
  "Life Adult Pin" and "fly fishing" finds "Fly Fishing".  An exact hit wins,
  and anything else containing the words is listed after it under
  "Also on the sheet" — that is how "first class" shows the patch and then
  points at the two pin rows.
- `--category` takes a tab name: `Ranks`, `Positions`, `Awards`, `Merit Badges`.
  Those four tabs *are* the inventory; the sheet also carries working tabs the
  Advancement Chair adds and deletes, and the script skips those rather than
  trying to read them.  `verify` and `info` name what was skipped, so a tab
  that ought to be read cannot go missing quietly.
- `--section` takes a block index within a tab.  Only `Ranks` has more than one:
  section 0 is the rank patches, section 1 is the rank pins.
- All query commands accept `--json`.
- `info` reports the sheet URL, the sync time, per-tab totals, and the oldest
  physical count on the sheet.

The sheet URL comes from `TROOP-SETTINGS.md`'s "Badge inventory sheet" entry.
The script reads that file itself, so nothing needs to be exported; set
`BADGE_INVENTORY_URL` only to point it at a different sheet.  If
`TROOP-SETTINGS.md` doesn't exist yet, copy `TROOP-SETTINGS.md.example` and fill
it in.  The sheet must be shared as "anyone with the link can view" — there are
no Google credentials involved, and a sheet that stops being link-shared makes
`sync` fail with a message saying so.

## Two dates, and why the second one is the answer

Every number on the sheet has two ages, and **only one of them is about the
number being right**:

- **`synced_at`** — when this script last downloaded the sheet.  Kept fresh
  automatically.  It tells you the cache matches the spreadsheet.
- **`Last Checked`** — when a human last opened the box and counted.  This is
  the one that decides whether to trust the number, and the script prints it
  next to every count for exactly that reason.

A count synced thirty seconds ago that was last physically counted in January
is a January count.  **Always report the number with its check date**, and when
the date is old, say the count may be out of date rather than presenting it as
current.  `stale` is how you find those; `info` names the oldest one on the
sheet.

Patches also leave the box between counts.  A `Notes` entry like "last awarded
to ..." is the Advancement Chair's own record of what has gone out since, so
read the note before treating a count as the number on hand today.

## Reading the answer

- **Give the number, the item name as the sheet spells it, and the check date.**
  Three facts, not one.
- **A count of 0 means the sheet says none are on hand** — that is a real
  answer, and the useful one, because it is an order to place.  A blank count is
  different: nobody has ever written a number in that cell, and the script shows
  it as `—`.  Do not read a blank as zero.
- **The sheet is not a catalog.** An item missing from it is not evidence the
  troop has none; it may simply never have been tracked.  Say "it is not on the
  inventory sheet", not "we don't have any".
- **Rank patch and rank pin are different rows.**  "Life" is the patch;
  "Life Youth Pin" and "Life Adult Pin" are the pins given to the Scout and to
  a parent.  Do not merge them, and be sure which one was asked about.
- **There are no Eagle pin rows.**  `verify` says so on every run.  The Eagle
  items are stored elsewhere, as the sheet's own notes suggest — report that
  they are not tracked here rather than reporting zero.
- **`Out of Date` is not part of the count, and must never be added to it.**
  The Merit Badges tab has a sixth column counting patches that are in the box
  but of a retired design.  Athletics reads `Count` 1 and `Out of Date` 2 —
  that is one patch to hand a Scout, not three.  Report it as the separate
  thing it is: "1 on hand, plus 2 of an older design".  `outdated` lists every
  such row, and `verify` names them on every run.
- **An out-of-date patch does not fill an order.**  If a Scout earned Lifesaving
  and the sheet says `Count` 0 with `Out of Date` 2, the answer is still that
  one has to be bought.  Mention the old ones only as a footnote — the
  Advancement Chair may decide an older border is fine, but that is their call
  to make, not an assumption to build the answer on.
- Quote a `Notes` cell when it changes the answer.  Several are questions the
  Advancement Chair left for themselves ("who do we give these to?"), and a few
  flag an old design or a second storage location.  The rows with an
  `Out of Date` count usually have a note saying what is wrong with them
  ("older green border", "no PFD on rower") — that note is the useful half of
  the answer.

## Requirement text and counselors come from elsewhere

This skill reports inventory and nothing else.  The Merit Badges tab is a list
of *patches in a box*, not a list of what a badge requires and not a statement
that a badge exists.

- For what a badge or rank requires, use **scout-req**.  It is the only reader
  of the requirements book and the 2026 change list, and it is loud about the
  badges neither can answer for.
- For who can counsel a badge, use **mbc**.
- The sheet carries badges the 2025 printing does not have — Artificial
  Intelligence, Cybersecurity, and American Indian Culture (which is taking over
  from Indian Lore).  `verify` names them on every run.  **Never quote
  requirements for one of those from anywhere**; route it through `scout-req`,
  which will exit 3 and tell you to get them from scouting.org.

## Privacy

The `Notes` column names Scouts — "last awarded to ..." — and the repository is
public.  `.claude/skills/*/.cache/` is gitignored, which covers
`inventory.db`, and the sheet itself lives in Google Drive rather than in the
repo.  Keep it that way: never paste a note, a `--json` dump, or any other
output naming a Scout into a tracked file, a commit message, or a PR
description.  Telling the Advancement Chair in a session is the whole point;
committing it is not.

## Facts about the spreadsheet the script depends on

These were established by getting them wrong first.  The script's own header
carries the same list next to the code each one constrains — read both before
changing the parser.

- **The sheet is link-shared and read over plain HTTP.**  No Google credentials.
  If it is ever locked down, the CSV endpoint starts serving an HTML sign-in
  page; the script checks the response's content type so that arrives as an
  error instead of parsing into one wide column of nonsense.
- **`export?format=csv` with no `gid` returns the first tab, and the first tab
  is not `gid=0`.**  In this sheet `gid=0` is "Positions" while the first tab is
  "Ranks".  Every fetch passes an explicit gid.
- **Tab names and gids are scraped from the sheet's `/htmlview` page.**  There
  is no unauthenticated API that enumerates the tabs of a sheet, and the CSV
  endpoint accepts a gid but will not list them.  The htmlview HTML embeds one
  `items.push({name: ..., gid: ...})` per tab, in tab order.  This is the one
  brittle step, so it fails loudly rather than returning a partial sheet — an
  inventory missing a whole tab looks complete and is not.
- **Not every tab on the sheet is inventory.**  It is the Advancement Chair's
  working document, so it gains and loses scratch tabs — a "CoH 2026-08-25"
  court-of-honor worksheet, for one — whose columns look nothing like the
  inventory's.  `INVENTORY_TABS` names the four that are the inventory and the
  rest are skipped.  The loudness moves rather than goes away: **one of the four
  going missing is still a hard failure**, because an inventory short a whole
  tab looks complete and is not, and the skipped ones are named by `verify` and
  `info` so a tab that should be read cannot vanish without a word.
- **All four inventory tabs share one five-column shape**: a label column, then
  `Count`, `Last Checked`, `Checked by`, `Notes`.  Only the first header cell
  differs per tab ("Rank", "Position", "Award", "MB"), so the header check
  covers the other four and the first is just recorded.
- **`Out of Date` is a sixth column, and the sheet keeps it out of `Count`
  deliberately.**  Only the Merit Badges tab has it so far.  Athletics reads
  `Count` 1 and `Out of Date` 2, so the two cannot be summed — doing it would
  claim three patches the troop cannot hand out.  It is stored as its own field
  and folded into no total anywhere, including `info`'s per-tab "on hand" and
  the numbers `coh-shopping-list` subtracts.  Unlike `Count`, **a blank here is
  0, not NULL**: the column is filled in only for the few rows that have an old
  patch in the box, so blank is the sheet saying "none of these", not "nobody
  has counted".  Anything non-numeric in that cell stops the sync and names the
  row, rather than being quietly read as zero.
- **Blank rows are section breaks, not end-of-data.**  The "Ranks" tab holds the
  rank patches, then two blank rows, then the rank pins.  A parser that stopped
  at the first blank row would silently drop every pin — half that tab.  A run
  of blank rows is one break, which is why the pins are section 1 and not
  section 2.
- **The Merit Badges tab is not the book's badge list.**  It runs ahead of the
  2025 printing by three badges and spells Fly-Fishing as "Fly Fishing".
  `normalize` folds punctuation so the hyphen is not a mismatch, and it must
  stay identical to `normalize` in `req.rb` and `mbc.rb`.
- **A blank count is stored as NULL, not 0.**  "Nobody has written a number
  here" and "we have none" are different answers and only one is an order to
  place.

**Never trust a parse that fails `verify`.**  The sheet has no tally row, so
`verify` leans on what the shape of a hand-kept inventory guarantees: every row
named, counted, and dated; no date unparseable or in the future; no duplicate
name within a tab; and every badge in the requirements book present on the
Merit Badges tab, resolved through `scout-req` rather than by opening the book.
Post-2025 badges, missing rank/pin combinations, out-of-date patches, and the
non-inventory tabs that were skipped are reported as notes rather than
failures, because every one of them is a true statement about the troop and not
a parse error.
