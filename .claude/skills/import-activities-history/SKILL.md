---
name: import-activities-history
description: Read a TroopMaster "Individual Participation" report into a local database — every Scout's dated service hours, conservation hours, camping nights, hiking miles, and attendance — so a plan can say how many hours a Scout still owes rather than only that the requirement is open.
---

# Import Individual Participation

Turn a TroopMaster **Activities > Individual Participation** report into rows in
a local SQLite database, one activity per row, each dated, typed, and carrying
the hours, nights, or miles it was worth.

This is the report that answers **"how many service hours does this Scout still
owe?"** The Individual History report says only that the Service Project
requirement is unsigned. This one says the Scout logged three hours since the
day they earned First Class, two of them conservation, on these dates, at these
events.

**It stores and it sums. It decides nothing.** It will tell you a Scout logged
3 hours of `Serv Proj` and 2 of `Conservation` after a date you name. It does
not know that Star asks for six hours, that Life asks for three of them to be
conservation-related, or when the Scout earned the rank those hours have to
follow. The rank dates live in `individual-history` and the requirement text
lives in `scout-req`; putting the three together is
`generate-advancement-plan`'s job.

## Getting the report

In TroopMaster: **Activities > Individual Participation**, all Scouts, and set
the date range **wide** — wider than the oldest rank date in the troop. Save it
to `reports/Activities-IndividualParticipation-YYYY-MM-DD.pdf`.

The date range matters more here than in any other report this repo reads. See
"The window is a filter" below; it is the one thing about this report that can
produce a confident, wrong, and plausible-looking answer.

## Tool

`scripts/activities.rb` parses the report and owns the database. It needs
`pdftotext` (`brew install poppler`) and the repo's gems.

```
ruby scripts/activities.rb verify [REPORT.pdf]     # parse check — run this first
ruby scripts/activities.rb import [REPORT.pdf]     # verify, then store; --force overrides
ruby scripts/activities.rb list                    # who is loaded, and how old the data is
ruby scripts/activities.rb show   NAME             # one Scout's totals and activity log
ruby scripts/activities.rb json   [NAME]           # the same, machine-readable
ruby scripts/activities.rb hours  NAME [options]   # sum the rows between two dates
ruby scripts/activities.rb stale  [--days N]       # whose data is too old to plan from
ruby scripts/activities.rb notes  [REPORT.pdf]     # only what is worth knowing
```

`hours` takes `--type "Serv Proj,Conservation"`, `--since YYYY-MM-DD`, and
`--until YYYY-MM-DD`. With no report path, the newest
`Activities-IndividualParticipation-*.pdf` in `reports/` is used.

**Always run `verify` first, and never import a parse that failed it.**
`import` refuses on its own, but read the failures rather than reaching for
`--force`, which only overrides the *freshness* guard and never a bad parse.

### What `verify` checks

The report prints its own tally twice over, and that is what the whole parse
rests on. After each Scout's activity rows come a `# / Amount` block — a count
and a summed amount for every one of the 28 activity types — and a `# / Total`
block. `verify` re-derives both from the rows it read and compares them type by
type. On the troop's current report that is 1086 rows against 2128 declared
figures, and a single misassigned row breaks it.

It also insists that every scrap of text on every page is claimed by some
section, that every Scout's summary covers all the types the report declared for
them, that every activity date falls inside the report's own window, that no
Scout attended more events of a type than were offered to them, and that no two
Scouts share an identity. Unknown activity levels, unknown markers, negative
amounts, and a filename that disagrees with the PDF's generation date are
*notes* rather than failures — each is a true fact about the report rather than
a misparse.

## The window is a filter, not a Scout's history

The report opens every page with its date range:

```
01/03/25 - 08/30/26 ( #Cabin Camp +Pitch Tent *Prior to Date Joined Unit )
```

Everything before `window_start` is **simply absent**. For a Scout who earned
Star before the window opened, the hours they have already done are not in the
file, and any count of them comes out too low — which reads as a Scout who owes
more service than they do, and sends them to redo work they finished.

Two things follow, and both are already built in:

- The window is stored per Scout, and `show` prints it.
- **`hours --since` refuses a date before the window** rather than answering
  short. If you hit that error, the fix is a wider report, not a workaround.

When you ask for the report, set the range to cover the oldest rank date in the
troop. `ruby ../individual-history/scripts/history.rb roster` shows them.

## What the report carries

Every activity is one row: date, level, event title, type, amount, location,
remarks. The **amount's unit depends on the type**, and the report declares it:

| Type | Unit | What it answers |
| :--- | :--- | :--- |
| `Serv Proj` | hours | Star req. 4 and Life req. 4 service hours |
| `Conservation` | hours | the same, and Life's conservation condition |
| `Camping` | nights | Camping merit badge req. 9a's twenty nights |
| `Hiking` | miles | Hiking and Backpacking merit badges |
| `Riding` | miles | Cycling and Horsemanship |
| everything else | a bare count | attendance |

`Camping` rows carry a marker from the page legend: **`+` is a pitch-tent night
and `#` is a cabin night**, and the distinction is not cosmetic — Camping req.
9a counts nights under tent or approved shelter and cabin nights do not qualify.
The marker is stored beside the type and folded into nothing.

### Attendance, and what the denominator means

Each type also carries `5 of 29` — five camping events attended of twenty-nine
**offered to that Scout**. It is not a troop-wide event count: the March 2026
crossover cohort all show `7`, the March 2025 cohort `26`, and everyone older
`29`, because it counts opportunities since the Scout joined, clipped to the
window. An Individual-level activity of a Scout's own adds to their denominator
and nobody else's.

That is what makes the percentage an attendance **rate** and comparable between
Scouts. Reading the denominator as a troop-wide count makes every new Scout look
absent, which is the opposite of true.

## Reading service hours for a rank

This is the thing the skill exists for, and it is deliberately split in two: the
script sums, and the caller decides.

```
ruby scripts/activities.rb hours "Umbarger" --type "Serv Proj,Conservation" --since 2025-08-16
```

`--since` is the Scout's **rank date** — the day they earned the rank the
service must follow, which comes from `individual-history`, not from here. The
book is what settles the rest: hours count only while holding the prior rank
(`req.rb show Star`, `req.rb show Life`), and Life puts a conservation condition
on part of them.

Two facts about the troop's data, both confirmed against TroopMaster's own
figures on the Target Eagle report it replaces:

- **`Conservation` hours count toward the service total**, not separately from
  it. A Scout with two conservation hours and one service hour has three.
- **Life's shortfall is the larger of the two gaps.** A Scout six hours in with
  no conservation still owes three; a Scout three hours in with two of them
  conservation also owes three. Both were checked against what TroopMaster
  printed, and only that reading fits.

Do not encode either of those here. They are written down because a plan needs
them, and the place they belong is `generate-advancement-plan`.

## Working with the other skills

- **individual-history** — the rank dates every `--since` needs, and the record
  of what is signed. Both caches key on the same BSA ID, so they join: on the
  troop's current reports all 38 Scouts match, with rank, rank date, date of
  birth, and name agreeing across two independently parsed PDFs.
- **generate-advancement-plan** — where the hours become a plan. It holds the
  rank date, the six-hour threshold, and the conservation condition.
- **troop-advancement-plan** — where the camping nights and the attendance rates
  become a cohort finding: how many nights short the Camping cohort is against
  how many the calendar offers, and which Scouts have quietly stopped coming.
- **scout-req** — the requirement text. Nothing here is requirement text; the
  activity type names are the troop's own TroopMaster setup and the units are
  the report's.
- **troop-calendar** — whether an opportunity exists. This report says what a
  Scout has done; the calendar says what they will be able to do.

## Privacy

**This repository is public and this report is a roster of minors** — names,
emails, phone numbers, dates of birth, BSA IDs, and where each of them was on
given weekends.

The database lives in this skill's `.cache/`, which `.gitignore` covers. Names
are fine in a session and in an answer to the Advancement Chair. They never
reach a tracked file, a commit message, a branch name, or a PR description —
summarize a change as "re-import the participation report", never by who is in
it. Any Scout named in this file is invented.

## Facts about the report the script depends on

These live in full in the header of `scripts/activities.rb`, next to the code
they constrain. Read them before changing the parser. The four that most often
get reinvented wrong:

- **`-bbox-layout`, not `-layout`.** An event title runs into its Type with a
  single space — `Soil & Water Conservation MB MB Program` — so under `-layout`
  there is no way to know the type is `MB Program` and not `Conservation`. A
  `-layout` parse of the current report gets 12 rows wrong across 38 Scouts, and
  each is a plausible activity filed under the wrong heading. Words are bucketed
  into columns by their own x, and the column origins are read off the table's
  own header row rather than hard-coded.
- **The page header starts with a date.** A filter that takes "starts with a
  date" as the mark of an activity row swallows the window/legend line on all 91
  pages. Activity rows must also sit below the table header.
- **The `# / Percent` block cannot be read positionally.** Where the denominator
  is zero it prints `0 /` with nothing after it, so 13 headings can carry 8
  readable values. It is skipped deliberately — it is exactly `count / offered`
  — and `verify` re-derives it as a guard on that pairing instead.
- **The window, again.** It is the single most dangerous fact here, because
  being short on hours reads as a Scout who has done less work rather than as a
  report that was run too narrow.
