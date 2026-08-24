---
name: coh-shopping-list
description: Turn a TroopMaster "Court Of Honor" report into a Scout Shop order — what the troop already holds, and what has to be bought before the ceremony.
---

# Court of Honor shopping list

Answer **"what do I need to buy before the court of honor?"** by subtracting
what the troop holds from what the ceremony hands out.

The input is a TroopMaster **Court Of Honor** report — every rank, merit badge,
National Outdoor Award, and special award earned in one award period, listed per
Scout and then totalled in an Awards Summary.  The other half of the answer is
the badge inventory sheet, reached through the **`badge-inventory`** skill.

This skill does arithmetic between a report and a box of patches.  It never says
what a Scout has earned, what a badge requires, or who may counsel it.

## The two clocks — the thing to get right

Troop 400 distributes on two different schedules, and **the order splits along
that line**:

| | Distributed | Appears in the order as |
| :--- | :--- | :--- |
| Rank patches, position patches | **Immediately**, the day it is earned | a **restock** — the box gets rebuilt |
| Merit badges and their cards, special awards, National Outdoor Awards, **both** rank pins | **Held for the court of honor** | a **count of what to hand out** |

So a Scout who reached First Class, earned two merit badges, and earned World
Conservation is already wearing the First Class patch.  At the ceremony they
receive the two merit badges and their two cards, World Conservation, and the
First Class **youth and adult pins** — two pins, one for the Scout and one for
a parent.

Getting this backwards produces an order that is wrong in both directions at
once: it buys rank patches nobody is waiting for, and misses the pins that are
actually short.  A rank in the report means **two pins**, not a patch.

## Tool

`scripts/coh.rb` parses the report, calls `badge-inventory` for the counts, and
does the subtraction.  Needs `pdftotext` (`brew install poppler`).

```
ruby scripts/coh.rb verify  REPORT.pdf   # parse check — run this first
ruby scripts/coh.rb badges  REPORT.pdf   # merit badge names, one per line
ruby scripts/coh.rb awards  REPORT.pdf   # what the ceremony hands out, and what is short
ruby scripts/coh.rb restock REPORT.pdf   # rebuilding the immediate-award stock
ruby scripts/coh.rb order   REPORT.pdf   # the whole order, plus what to check first
ruby scripts/coh.rb notes   REPORT.pdf   # only the things worth checking first
ruby scripts/coh.rb json    REPORT.pdf   # the whole computation
```

`order` is the usual entry point; the others are its pieces.

**Always run `verify` first, and never report an order from a parse that failed
it.**  Unlike the Target grids, this report carries its own tally: each Awards
Summary section declares a total ("107 Merit Badges").  `verify` checks that
total against the summary's own line items *and* against an independent re-tally
of the per-Scout detail pages, item by item — three numbers that must agree.  It
also refuses an award kind it does not recognise, which would otherwise be
dropped from the order in silence.

## Then check the badge names

```
ruby scripts/coh.rb badges REPORT.pdf | ruby ../scout-req/scripts/req.rb check
```

The reason differs from `target-eagle`'s.  A patch does not change when its
requirements do, so **the "changed for 2026" note does not affect the order** —
ignore it here.  What matters is **exit 3**: a badge neither the 2025 printing
nor the 2026 change list carries is a badge that very likely has no row on the
inventory sheet either, so it will surface as "not tracked" rather than as a
real count.  That is a patch the troop may have never stocked.  Say so plainly
rather than reporting it as a zero.

## Merit badge cards are bought by the package, and nobody counts them

Every merit badge handed over comes with a **merit badge card**, so the need is
simply the report's own merit badge total — 107 badges is 107 cards.  Two things
make that line read differently from every other line on the order:

- **The Scout Shop's usual unit is a package of 100.**  Single cards turn up but
  are not reliable, so the order is a whole number of packages, **rounded up**.
  The script never prints a bare package count: `2` against a need of 107 is two
  packages, not two cards, so it always says both — `2 packages of 100 (200)`.
  For the same reason the running total keeps packages out of the item count —
  `Total items to buy: 11, plus 2 packages of merit badge cards (200)`.
- **The inventory sheet has no row for cards, and is not meant to grow one.**
  The sheet is a record of patches in a box; nobody tallies a drawer of cards.
  So the number is a **ceiling** — what the ceremony needs, before subtracting
  whatever is already in the drawer.  Say that when you report it, the way you
  say it for the NOA pentagon.  `notes` lists the line under "Bought by the
  package, and never counted" for exactly this reason.

This is the one item on the order the sheet cannot answer for, and it is
deliberately *not* the same thing as "not tracked on the inventory sheet" —
that heading means a row is missing and someone should go look.  Cards will
never have one.

## An out-of-date patch does not fill an order

The inventory sheet counts patches of a **retired design** in a column of their
own, `Out of Date`, and it is **not part of `Count`** — Lifesaving reads `Count`
0 and `Out of Date` 2, which means nothing to hand out, plus two of an older
silver border sitting in the box.  The order follows the sheet exactly: an
out-of-date patch is never in the on-hand number, never reduces what to buy, and
never takes a line off the list.  Two of those Lifesaving patches still means
buying two.

It is still worth saying out loud, because it may change the trip.  Every line
whose row has one carries `plus 2 of an older design` in its Notes column, and
`notes` lists them under **"Older design in the box, counted separately"** —
with the sheet's own note on what is wrong with them ("no PFD on rower", "2 have
older silver border; look older") and how much of the order could come off if
the older border will do.

**That last decision belongs to the Advancement Chair**, and the job here is to
hand them what they need to make it — not to make it for them in either
direction.  Do not quietly subtract the old patches, and do not leave them out of
the answer either.  For the whole list, whether or not it is on this order:

```
ruby ../badge-inventory/scripts/inventory.rb outdated
```

## The National Outdoor Award is three purchases, not one

The award has up to three parts, and the Scout Shop sells them separately:

1. The **pentagon-shaped base badge** — the "NOA badge", or "award center
   emblem".  This is the award itself.
2. One or more **segments** — Riding, Hiking, Camping, Aquatics, Adventure,
   Conservation — sewn around the pentagon.
3. Optional **gold and silver devices**, which are small **pins**, not patches.
   One is added to a segment patch already on the uniform to mark further
   experience on it.

The report names two of the three:

| The report says | It means |
| :--- | :--- |
| `NOA - Hiking`, under **National Outdoor Awards** | the Hiking segment patch |
| `NOA Camping Gold`, under **Special Awards** | a gold device pin for the Camping segment |

**It never names the pentagon**, because a Scout needs one only with their very
first segment, and TroopMaster does not record it separately.  So the script
infers it — **one pentagon per Scout who earned any segment in this period** —
and that number is a **ceiling, not a count**.  A Scout who earned Hiking two
years ago and Camping now needs no second pentagon, and nothing in this report
can tell you which case you are looking at.

**Say this out loud when you report the order.**  The pentagon line carries the
caveat in its Notes column, and `notes` lists the Scouts by name under "Earned
an NOA segment — check whether they already have the pentagon".  Hand the
Advancement Chair that list: only each Scout's own advancement history settles
it.  Carrying a spare pentagon is cheap and the troop stocks them, so the usual
answer is "buy it if the box is low" — but the check before it is sewn on is
theirs to make, not something to quietly skip.

Two more things follow from how the parts work:

- **A device does not imply a pentagon.**  A device goes on a segment the Scout
  is already wearing, so only *segments* put a pentagon on the order.
- **A gold device is the same pin whichever segment it goes on**, so all the
  gold lines are added up and subtracted from one stock.  The order shows
  `National Outdoor Awards (Gold Device)` — the sheet's own row — with the
  segments it is destined for in the notes, rather than one line per segment.
  Left separate, two needs of one against a stock of one would both come out
  covered.

## Reading the answer

- **Give the number, the item name as the *sheet* spells it, and the check
  date.**  The script prints the sheet's spelling once it matches, because that
  is what the item is ordered and filed under — the report's "Fish and Wildlife"
  is "Fish and Wildlife Management" in the box.
- **"Not tracked" is not "we have none."**  The sheet is a hand-kept inventory,
  not a catalogue.  It has a row for the NOA gold device but none for the
  silver.  Report anything untracked as untracked and let the Advancement Chair
  check, rather than ordering as if the count were zero.
- **A blank count is not zero either.**  Nobody ever wrote a number in that cell.
- **An out-of-date patch is not stock.**  The sheet counts retired designs
  separately and so does the order; report them as the caveat they are, never as
  part of the count — see above.
- **Zero margin is worth saying out loud.**  Dozens of merit badge lines
  routinely come out at need exactly equals stock.  Anything that left the box
  since the last physical count turns one of those into a shortfall discovered
  at the ceremony.  `notes` lists them.
- **Read the sheet's `Notes` column when it changes the answer.**  "last awarded
  to ..." is the Advancement Chair's own record of what has gone out since.

## How lists are ordered

Every list this skill prints — the order, the shopping list, the notes, the JSON
— follows the same two rules, so no two views of the same run disagree:

- **Ranks run lowest to highest**: Scout, Tenderfoot, Second Class, First Class,
  Star, Life, Eagle.  Never alphabetically, and never in report order — the
  Awards Summary's two-column layout reads out as *Scout, First Class,
  Tenderfoot, Star, Second Class, Life*, which is the order of the page rather
  than the order of advancement.  Rank pins follow their rank, youth pin before
  adult pin.
- **Everything else is grouped by type — merit badge patches, merit badge
  cards, then awards — and sorted alphabetically by name within each group.**
  Not by how many to buy: a shopping list is read against a shelf, and the
  shelf is alphabetical.

The name that sorts is the one the item will be ordered under, which is the
sheet's spelling wherever it differs from the report's.

This is one `Item#sort_key` in `coh.rb`, applied at every point a list is
emitted, and `RANK_ORDER` is the single list of ranks.  A rank named in
`RANK_BANDS` but missing from `RANK_ORDER` is a hard error rather than an item
that quietly sorts to the end.

## How much rank stock to keep

Rank patches are gone by the time the report is printed, so the report cannot
say what to buy.  The troop's own stock bands do, and they live in `RANK_BANDS`
at the top of `coh.rb`:

- **Scout through First Class — keep 7 to 10** of each.
- **Star, Life, and Eagle — keep 5 to 8** of each.

Below the low end, order back up to the high end.  A band is a min/max, not a
target, so the box is not topped up on every trip.  `restock` covers **every**
rank, including ones nobody earned this period — a rank absent from the report
can still be short.  It also prints what the period consumed, as context for why
a rank is draining, but consumption is not what decides the order.

**Position patches are deliberately out of scope.**  They are immediate-award
too, but the troop keeps no target for them yet, so the script says so and
leaves them alone rather than guessing.

## Privacy

The report names a Scout on every page, and `notes` names them again when it
finds a duplicate award.  **The repository is public.**  Nothing this script
prints may reach a tracked file, a commit message, or a PR description.
Generated orders go in `plans/coh-shopping-list-YYYY-MM-DD.md`, dated from the
report they read; `plans/` is gitignored.  Telling the Advancement Chair in a
session is the whole point — committing it is not.

## Facts about the report the script depends on

These were established by getting them wrong first.  The script's own header
carries the same list next to the code each one constrains — read both before
changing the parser.

- **The Awards Summary is two columns of items, and only the column gaps
  separate them.**  A regex over the line happily reads
  `Citizenship In Nation* MB 10304 1 Metalwork MB` as one item name.  Split on
  runs of two-or-more spaces and take the fields positionally.
- **Special Awards carry no item code; every other section does.**  Rank, Merit
  Badge, and National Outdoor Award lines are (name, code, quantity) triples;
  Special Awards lines are (name, quantity) pairs.  Slicing all four sections by
  three shifts the Special Awards quantities into the names.
- **Detail lines name their kind only once.**  The first entry under a Scout
  reads `Merit Badge:  Insect Study MB  07/10/26`; the rest are bare
  continuation lines.  The parser carries the last-seen kind forward and clears
  it at each new Scout, so an unlabelled line is never orphaned.
- **A rank's on-hand count is only usable if it was taken after the award.**
  Rank patches leave the box the day they are earned, so a count from before a
  Scout ranked up still includes a patch that is already on a uniform.  The
  script subtracts any award dated after the row's `Last Checked`, and `verify`
  reports per rank whether that subtraction was needed rather than assuming it
  was not.  In a healthy report it is zero for every rank.
- **A count taken before the award period opened cannot reflect the last court
  of honor.**  The period is printed at the top of every page
  (`04/08/26 - 08/18/26`).  Counts older than that start date are reported as
  unreliable rather than used.
- **TroopMaster and the sheet do not spell things alike.**  Badge names carry a
  trailing `MB` and an `*` on the Eagle-required ones.  Past that, `normalize` —
  which **must stay identical to `normalize` in `req.rb`, `mbc.rb`, and
  `inventory.rb`** — drops "and" and "the", so "Citizenship In Nation*" meets
  "Citizenship in the Nation" and "Small Boat Sailing" meets "Small-Boat
  Sailing".  Prefix matching in either direction closes the rest.  Only the
  National Outdoor Awards need help: nothing folds "NOA - Hiking" into
  "National Outdoor Awards (Hiking)", so the leading `NOA` is expanded.
- **A merit badge card goes out with every merit badge, and cards are sold by
  the package.**  The need is the report's merit badge total; the buy is that
  divided by 100 and rounded up.  Packages and single patches are different
  units and are never added into one number.  Nothing is subtracted, because
  the sheet has no row for cards — see the section above.
- **`Out of Date` is a column of its own on the sheet, and never part of
  `Count`.**  `inventory.rb` carries it as a separate field, and so does this
  script: it is not in `on_hand`, it never reduces a shortfall, and it is added
  into no total.  Athletics reads `Count` 1 and `Out of Date` 2 — one patch to
  hand a Scout, not three.
- **A National Outdoor Award is up to three separate purchases**, and the report
  names only two of them — see the section above.  A segment line
  (`NOA - Hiking`) is a patch, a device line (`NOA Camping Gold`) is a pin, and
  the pentagon is never printed at all.  `verify` rejects any `NOA` line that is
  neither a known segment nor a gold/silver device, because such a line would
  otherwise be priced as an ordinary award and skip the pentagon entirely.
- **Lookups are scoped to the tab that can hold the item**, so a loose prefix
  cannot reach across into a different kind of patch — the Kayaking merit badge
  and the Kayaking BSA award are different rows on different tabs.
- **Rank pins are the Ranks tab's second block**, not the first.  `inventory.rb`
  exposes that as `section_index` 1; the patches are section 0.  The two must
  never be looked up in the same pool.
- **The same award to the same Scout on two dates is almost always a double
  entry**, not a second award, and it inflates the order.  `notes` lists them
  with both dates so the Advancement Chair can decide.

**Never trust a parse that fails `verify`.**  A misparse of this report does not
look broken — it looks like a slightly different order.

## Requirement text, counselors, and counts come from elsewhere

- Inventory numbers come from **`badge-inventory`**, never by reading the
  spreadsheet here.
- What a badge requires comes from **`scout-req`**, the only reader of the
  requirements book and the 2026 change list.
- Who may counsel a badge comes from **`mbc`**.
