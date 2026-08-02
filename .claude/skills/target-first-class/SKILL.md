---
name: target-first-class
description: Turn a TroopMaster "Target First Class" report into an advancement plan and to-do list — read the requirement grid, group Scouts by the rank they are working on, find the time-clocked and shared requirements, and schedule the work against the troop calendar. Use whenever someone hands over a Target First Class report, asks who is close to Tenderfoot/Second Class/First Class, asks what to program at meetings or a Saturday at the Shed, or wants to know what stands between the troop and the next court of honor.
---

# Target First Class

Build an advancement plan for the Scouts in a TroopMaster **Target First Class**
report — the ones working toward Scout, Tenderfoot, Second Class, and First Class.

The report says what is *done*. The plan's job is to say what to *do*, in what
order, on which dates. Most of the value is in three things the grid does not
state: which requirements have a calendar clock attached, which ones many Scouts
need at once, and whether the conference and board load fits in the meetings
available.

## Tool

`scripts/tfc.rb` rebuilds the grid from the PDF's word bounding boxes. Needs
`pdftotext` (`brew install poppler`).

```
ruby scripts/tfc.rb verify  REPORT.pdf                 # parse check — run this first
ruby scripts/tfc.rb summary REPORT.pdf                 # cohorts, items left, SMC/BoR load
ruby scripts/tfc.rb gaps    REPORT.pdf [--scout NAME] [--all-ranks]
ruby scripts/tfc.rb batch   REPORT.pdf [--min N]       # requirements several Scouts share
ruby scripts/tfc.rb json    REPORT.pdf                 # whole parse, for ad-hoc analysis
```

**Always run `verify` first, and never report numbers from a parse that failed
it.** The report prints its own "Scouts Needing:" tally under every column; the
script recomputes those counts from the grid it built and compares all 121. That
cross-check is the only thing standing between a plausible-looking plan and a
wrong one.

### Facts about the report the script depends on

All verified against the 8/1/2026 report:

- **Do not read the grid any other way.** The headers are rotated and the marks
  are single glyphs on a ~5.5pt pitch. Plain `pdftotext -layout` interleaves the
  columns and silently misaligns marks; reading page 1 as an image is illegible
  at that density. Bounding boxes are the only reliable route.
- **`X` and `/` both mean complete.** `/` is credit that came with a rank award
  rather than an individually dated sign-off — every Scout-rank holder shows `/`
  on Scout 6b, and a Scout whose whole Scout rank was credited that way shows a
  row of them. Treating `/` as incomplete breaks the tally cross-check
  immediately, which is how this was confirmed.
- **Rotated headers lose single-part codes.** "Scout 5" extracts as bare
  "Scout". The 121 column names are therefore hardcoded in `RANKS`; the script
  asserts the count and the per-rank run-lengths (19 / 27 / 37 / 38) and refuses
  to run if a future report disagrees.
- **The awarded rank is the line below the name,** and is blank for a Scout who
  has not earned Scout rank yet. Do not confuse it with the rank being worked on.

## The analysis

### 1. Group by working rank, not by awarded rank

A Scout's **working rank** is the lowest one not yet complete. `summary` does
this. It matters because requirements for Scout through First Class "may be
worked on simultaneously; however, these ranks must be earned in sequence"
(*Guide to Advancement 2025*, 4.2.0.1, printed p. 18) — so a Scout can have a
pile of First Class requirements signed and still be blocked behind Scout rank.

**Look for exactly that.** A Scout with many requirements banked above an
unearned rank is the highest-yield case in any report: a handful of easy items
converts a large amount of invisible work into a rank.

### 2. Find the time-clocked requirements first

Most requirements can be done any time. A few cannot be compressed, and they are
what actually decides which court of honor a Scout makes. In the 2025
requirements the fitness chain is strictly sequential:

- **Tenderfoot 6b** — track activity for at least 30 days
- **Tenderfoot 6c** — show improvement *after practicing for 30 days*
- **Second Class 7a** — *after completing Tenderfoot 6c*, 30 min/day, 5 days/week, 4 weeks
- **First Class 8a** — *after completing Second Class 7a*, same again

Each link needs the previous one finished. A Scout advancing two ranks in a
season cannot overlap them. Note also that **Tenderfoot 6a (the fitness test)
must be recorded before 6b's log can start** — Scouts missing 6a are a step
further back than they look.

Always re-read the current requirement text from
`docs/Scouts-BSA-Requirements-2025.pdf` rather than trusting this summary;
requirements are year-versioned.

Other requirements to check for schedule dependence: swim tests (needs an
aquatics opportunity), orienteering courses, service projects, and anything
naming a specific number of days or activities.

### 3. Find what many Scouts need at once

`batch` lists requirements shared across a cohort. One meeting built around a
four-requirement cluster that six Scouts need is worth more than six individual
conversations. Say so explicitly in the plan, and name the evening.

### 4. Count the conference and board load

`summary` totals it. Every Scout needs a Scoutmaster conference for their working
rank; every rank except Scout also needs a board of review — "After completing
all the requirements for a rank, *except Scout rank*, a Scout meets with a board
of review" (*GTA* 4.2.1.3, printed p. 19). That exception makes the Scout-rank
cohort the fastest awards available before any court of honor.

## Troop 400 conventions

These are how this troop actually runs, and the plan must match them:

- **Conferences and boards are never scheduled as separate events.** They happen
  inside regular meetings, so they will never appear on the calendar. Do not
  report their absence from the feed as a finding.
- **Plan up to 3 conferences or 3 boards per meeting.** The constraint is
  meeting-night capacity, not calendar space. Divide the total load by the
  meeting nights available and check it fits — then spread it, because batching
  it before a court of honor does not work.
- **Conferences and boards can run concurrently.** Committee members conduct
  boards and "may not test or pass Scouts on rank requirements" (*GTA* 4.2.1.2,
  printed p. 19), so board reviewers are never drawn from the sign-off crew.
- **Collapse the closing three requirements.** Scout Spirit, Scoutmaster
  conference, and board of review are reported as one line — **"needs an SMC/BoR
  meeting"**, or **"needs an SMC meeting"** at Scout rank. Everything else listed
  for a Scout should be real program work. The script already does this.

### Saturday at the Shed

Intensive rank sign-off and training sessions — roughly **3–4 hours** with
**6–7 adult leaders** signing off. Per hour and per adult, the most productive
advancement venue the troop has. Plan every one that falls in the window:

- Split the leader roster between **Target First Class** rank sign-offs and
  **Target Eagle** merit badge sign-offs, reserving a meaningful share for each.
- Structure it as a short all-hands opener plus **~3 rotating stations**, and
  name the specific requirements and Scouts each station can clear. Group
  physical requirements (a measured mile, fitness tests) into the opener.
- A session can also absorb **~3 conferences and ~3 boards**. Conferences cost
  sign-off capacity — they take the Scoutmaster out of the rotation for about 15
  minutes each. Boards do not, since committee members are not sign-off leaders.
- **Check how many Shed dates are actually in the window.** There may be only
  one, or none. Say so plainly, and consider recommending another.

## Working with the other skills

- **troop-calendar** — get the real dates. Anchor every piece of program work to
  a scheduled event, and flag requirements with *no* opportunity on the calendar
  (a swim test with no pool date is a Scout who cannot finish, and that is worth
  more to the reader than another to-do line).
- **guide-to-advancement** — get the policy, with citations. Use it for anything
  about sequence, sign-off authority, boards, or conferences.
- **`docs/Scouts-BSA-Requirements-2025.pdf`** — the requirement text itself,
  especially wherever a time period or a prerequisite is involved.

State the calendar fact and the advancement implication separately. The calendar
shows something is scheduled, not that a Scout attended or that a requirement was
met.

## Writing the plan

Lead with the two or three findings that change what leaders should do, not with
a roster dump. A good plan has answered: *what is the one thing that must start
this week, what converts the most work into rank the fastest, and does the
conference and board load fit?*

Suggested shape:

1. **Cohorts** — who is working on what, and how many are one rank away.
2. **Findings** — the time clocks, the banked-work cases, the throughput math.
3. **Meeting-by-meeting plan** — program focus plus conference/board load per
   night, with no night over the cap.
4. **Saturday at the Shed** — full session plan for each one in the window.
5. **Calendar hooks** — which event supports which requirements, plus the gaps
   that need a date booked.
6. **Per-Scout to-do lists** — program work, then the collapsed meeting line.
7. **Batch opportunities** — what one evening can clear for several Scouts.
8. **Leadership to-do list** — ordered by urgency, not by size.

Write plans to `plans/target-first-class-YYYY-MM-DD.md`, dated from the report.

Two things to keep honest: distinguish what the report states from what you are
estimating (projected advancement counts are an estimate — label them), and when
a Scout cannot realistically make the next court of honor, say so and give the
date they can make instead.
