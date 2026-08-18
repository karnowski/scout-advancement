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
| Merit badges, special awards, National Outdoor Awards, **both** rank pins | **Held for the court of honor** | a **count of what to hand out** |

So a Scout who reached First Class, earned two merit badges, and earned World
Conservation is already wearing the First Class patch.  At the ceremony they
receive the two merit badges, World Conservation, and the First Class **youth
and adult pins** — two pins, one for the Scout and one for a parent.

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

## Reading the answer

- **Give the number, the item name as the *sheet* spells it, and the check
  date.**  The script prints the sheet's spelling once it matches, because that
  is what the item is ordered and filed under — the report's "Fish and Wildlife"
  is "Fish and Wildlife Management" in the box.
- **"Not tracked" is not "we have none."**  The sheet is a hand-kept inventory,
  not a catalogue.  It has no row at all for the NOA gold devices.  Report those
  as untracked and let the Advancement Chair check, rather than ordering as if
  the count were zero.
- **A blank count is not zero either.**  Nobody ever wrote a number in that cell.
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
- **Everything else is grouped by type — merit badges, then awards — and sorted
  alphabetically by name within each group.**  Not by how many to buy: a
  shopping list is read against a shelf, and the shelf is alphabetical.

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
