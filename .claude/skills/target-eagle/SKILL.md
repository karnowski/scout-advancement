---
name: target-eagle
description: Turn a TroopMaster "Target Eagle" report and Partial Merit Badges List into an advancement plan and to-do list.
---

# Target Eagle

Build an advancement plan for the Scouts in a TroopMaster **Target Eagle**
report — the ones working toward Star, Life, and Eagle.

This skill needs **two** reports, and the second one is where most of the value
is:

- **Target Eagle** — the grid. Says which rank requirements are done, how much
  active time and service is left, and how many merit badge slots are open.
- **Partial Merit Badges List** for the same Scouts — says *which* badges are in
  progress, what percent complete, and exactly which requirements are open.

The grid alone will tell you a Scout needs three more merit badges. Only the
partials list tells you that two of them are 98% and 97% done and can be closed
in one morning. Ask for both; a plan built on the grid alone is a roster dump.

Unlike Target First Class, the binding constraint here is rarely meeting-night
capacity. It is **merit badges, service hours, and the Eagle project** — and,
for the older Scouts, the 18th birthday.

## Tool

`scripts/te.rb` rebuilds the grid from the PDF's word bounding boxes and parses
the partials list. Needs `pdftotext` (`brew install poppler`).

```
ruby scripts/te.rb verify   REPORT.pdf                          # parse check — run this first
ruby scripts/te.rb summary  REPORT.pdf --partials PARTIALS.pdf  # cohorts, what is left, SMC/BoR load
ruby scripts/te.rb gaps     REPORT.pdf [--scout NAME]           # per-Scout next-rank to-do
ruby scripts/te.rb partials REPORT.pdf --partials PARTIALS.pdf [--scout NAME] [--min-pct N]
ruby scripts/te.rb batch    REPORT.pdf --partials PARTIALS.pdf [--min N] [--min-pct N]
ruby scripts/te.rb clocks   REPORT.pdf --partials PARTIALS.pdf  # multi-week requirements
ruby scripts/te.rb json     REPORT.pdf --partials PARTIALS.pdf
```

**Always run `verify` first, and never report numbers from a parse that failed
it.** This report prints no tally row, so the cross-check is the rank in
parentheses after each Scout's name: **every rank block below a Scout's printed
rank must be complete.** A Life Scout with a hole in the Star block means the
grid is misaligned, not that the Scout skipped something. `verify` also refuses
any mark that does not land within four points of a column centre and any page
where the 42 columns do not come out in the expected order.

### Facts about the reports the script depends on

All verified against the 8/1/2026 Target Eagle report and the 8/2/2026 partials
list.

- **Do not read the grid any other way.** `pdftotext -layout` interleaves the
  three rank blocks and silently misassigns marks — a Life Scout's Eagle merit
  badges land under Star. Bounding boxes are the only reliable route.
- **TroopMaster never marks the Star block's "SM Conf" cell.** It is blank for
  every Scout, including Life Scouts whose Star rank is plainly complete. The
  column carries no information at all, so the script drops it from every count
  rather than reading it as incomplete. The rank in parentheses, plus Scout
  Spirit and Star BOR, say whether the conference happened. **Do not report it as
  a gap.**
- **The rank in parentheses after the name is authoritative.** Use it, not the
  marks, to decide what a Scout is working on. See the merit badge caveat below
  for why the marks cannot be trusted for this.
- **A number means the requirement is *not* met.** Participation, Serv Proj, and
  Lead Pos print the amount *remaining* — days for Participation and Lead Pos,
  hours for Serv Proj. `X` in those columns means the clock has run out. Reading
  a number as "complete" inverts the whole report.
- **Mark meanings, from the report's own legend:** `X` complete, `*` complete
  *and* Eagle-required, `+` complete but a duplicate Eagle category. A `+` counts
  toward the Star and Life "from the required list" totals — those requirements
  say only "any four/three from the required list for Eagle" — but at Eagle it
  counts as one of the seven optional badges, because Eagle requirement 3 lets
  you use only one badge from each of categories (i), (j), and (l).
- **Merit badge slot counts are trustworthy; the required/elective split is
  not.** The grid has exactly 21 slots (6 Star + 5 Life + 10 Eagle), so the
  number of blank slots is the number of badges still needed for that rank. But
  a Scout who has earned more than seven electives spills the surplus forward
  into slots the grid then cannot use to show which *required* badges remain.
  Counting asterisks will make some Scouts look one Eagle-required badge short
  when they are not, and vice versa. **Read the missing required badges out of
  the partials list instead**, and if a Scout is near an Eagle application, say
  plainly that the 14 required categories must be confirmed in TroopMaster.
- **A short word rotated 90 degrees is short in *y*.** "til" and "18" in the
  "Months til 18" header are only 7 and 11 points tall, so a height filter drops
  them and the column comes out named "Months". The script seeds column
  positions from the long words and then collects the rest of each phrase by
  position.
- **In the partials list, `*` marks an Eagle-required badge and `#` marks
  Citizenship in Society**, which is also Eagle-required — the script counts both
  as required. If `#` ever appears on a different badge, re-check that
  assumption.
- **TroopMaster's badge names are not the requirements book's names.** It prints
  "Citizenship In Community" where the book says "Citizenship in the Community".
  The script compares badge names loosely for that reason; `clocks` ends by
  naming any entry that matched nothing, so a rename shows up instead of
  silently disabling a rule.

## The analysis

### 1. Sort by time remaining, not by rank

`summary` orders each cohort by the *Months til 18* column. That is the column
that decides everything for the older Scouts, and it is the one the grid buries
on the far right.

A Life Scout with fewer than about nine months and no Eagle project is an
emergency. Requirements 1–6 — including the project, the position of
responsibility, and the Scoutmaster conference — must all be complete **before**
the 18th birthday. Only the board of review may happen afterward, up to 24 months
without special approval (*Scouts BSA Requirements 2025*, Eagle rank footnote 13,
citing *Guide to Advancement* 8.0.3.1). That exception does not cover the
project, and a project proposal needs four approvals — the benefiting
organization, the Scoutmaster, the troop committee, and the council or district —
before any work starts.

Also check for a blank in that column when every other Scout has a number: it
usually means a missing date of birth in TroopMaster, which will break the Eagle
application later.

### 2. Find the Scouts who are one meeting away

`summary` ends with a "Ready now" line: Scouts with no merit badges and no
program work outstanding, needing only the conference and board. These are the
highest-yield names in the report, and the reason is not the rank itself — **the
next rank's clocks cannot start until this one is awarded.** A Star Scout who
could finish Life tonight but waits a month has moved their Eagle position-of-
responsibility completion back a month too. Say that explicitly in the plan.

### 3. Run `clocks` before anything else in the plan

This is the equivalent of the fitness chain in Target First Class, and it is
where the schedule actually gets decided. Requirements verified against
`docs/Scouts-BSA-Requirements-2025.pdf`:

| Badge | Requirement | Clock |
| :---- | :---------- | :---- |
| Personal Management | 2a budget, 2c tracking | **13 consecutive weeks**, and 2c must cover the same 13 weeks as 2a |
| Personal Fitness | 7 outline, 8 completion | **12 weeks**, with a retest every four |
| Personal Fitness | 1a, 1b | physical and dental exams **gate requirements 2–9** — weeks of booking lead time |
| Family Life | 3 | **90 days** of recorded home duties |
| Camping | 9a | **20 nights**, which is a season of campouts, not an afternoon |
| Citizenship in the Community | 7c | **8 volunteer hours** for the chosen organization — troop service hours do not count |
| Multisport | 5 | **4 weeks** of tracked training |

Work backwards from the next court of honor. A 13-week badge started the week of
the report finishes about three months later; started a month after, it misses.
Name the specific date the cohort has to start, and put it in the leadership
to-do list.

Always re-read the current requirement text rather than trusting this table;
requirements are year-versioned.

### 4. Look for badge-to-badge dependencies

`partials` flags these with `**`. **Emergency Preparedness requirement 1 is
"Earn the First Aid merit badge."** Both are Eagle-required, so:

- A Scout at 98% on First Aid and 97% on Emergency Preparedness is *one
  sign-off* from two Eagle-required badges. That is the cheapest advancement in
  any report.
- A Scout showing Emergency Preparedness requirement 1 open with **no First Aid
  in progress** is further from Emergency Preparedness than the percentage
  suggests, and needs First Aid started.

### 5. Find what many Scouts need at once

`batch` counts open requirements by badge and requirement number across the whole
roster. The most valuable rows are usually the Eagle-required badges where a
whole cohort is stalled at the same place — one structured session clears it for
six or seven Scouts. Citizenship in Society requirement 6 is a paired
conversation between two Scouts, so a cohort that all needs it *is* the resource;
pair them with each other.

Note that a Scout at 0% on a badge contributes every one of its requirements to
`batch`. Use `--min-pct 1` to see only badges someone has actually started, and
read `batch` alongside `partials`.

### 6. Check the service hours against the calendar

Star requires six hours. Life requires six hours of which **at least three must
be conservation-related** — a distinction the grid does not show, so read it out
of the requirement text. Hours count only while holding the prior rank ("While a
First Class Scout", "While a Star Scout"), so **a First Class Scout cannot bank
Life service hours**, and the same is true of active time and positions of
responsibility. `gaps` prints that warning.

Then look for a qualifying event. A Scout blocked on three conservation hours
with no conservation project on the calendar for two months is a Scout who cannot
finish, and that is worth more to the reader than another to-do line.

### 7. Check for a missing position of responsibility

Compare the Eagle block's Participation and Lead Pos numbers. When Participation
is counting down but Lead Pos still shows the full 180 days, the Scout **has no
position at all** — and troop elections may be months away. Most Eagle-qualifying
positions are appointed, not elected (scribe, librarian, historian, quartermaster,
instructor, webmaster, OA troop representative, JASM), so this is fixable the same
week. Note that bugler and assistant patrol leader do **not** count for Eagle.

## Troop 400 conventions

- **Conferences and boards are never scheduled as separate events.** They happen
  inside regular meetings, so they will never appear on the calendar. Do not
  report their absence from the feed as a finding.
- **Plan up to 3 conferences or 3 boards per meeting.** For a Target Eagle
  cohort this cap is usually slack, not a constraint — say so plainly rather than
  padding the plan with throughput math that is not binding. `summary` reports
  the eventual load and the ready-now load separately for exactly that reason.
- **Conferences and boards can run concurrently.** Committee members conduct
  boards and "may not test or pass Scouts on rank requirements" (*GTA* 4.2.1.2,
  printed p. 19), so board reviewers are never drawn from the sign-off crew.
  Only the Scoutmaster runs Scoutmaster conferences.
- **The Eagle board of review is not a troop board.** It is conducted per council
  policy, usually by the district. Do not schedule it into a troop meeting.
- **Collapse the closing three requirements** — Scout Spirit, Scoutmaster
  conference, and board of review — into one line, **"needs an SMC/BoR
  meeting"**. The script already does this. Eagle is written out instead, because
  Scout Spirit there also carries the reference list on the application.

### Saturday at the Shed

Intensive sign-off sessions, roughly **3–4 hours** with **6–7 adult leaders**.
Per hour and per adult, the most productive advancement venue the troop has, and
there are usually only two or three a year — **check how many fall in the window
and say so plainly.**

- Split the leader roster between **Target First Class** rank sign-offs and
  **Target Eagle** merit badge sign-offs.
- Use the opener for the thing that has to *start*, not finish: launching a
  13-week or 12-week clock for a whole cohort at once is worth more than any
  individual sign-off that morning.
- Then run **~3 rotating stations**, and name the specific requirements and
  Scouts each can clear. `partials --min-pct 85` gives the closeout list.
- A session absorbs about **3 conferences and 3 boards**. Conferences cost
  sign-off capacity — they take the Scoutmaster out of the rotation for about 15
  minutes each. Boards do not, since committee members are not sign-off leaders.

## Working with the other skills

- **troop-calendar** — get the real dates. Anchor every merit badge to an event
  that can actually close it: cooking requirements to a campout, Camping 9b to a
  canoe trip or a camporee, conservation hours to a cleanup, classroom badges to
  a merit badge college. Then flag the requirements with *no* opportunity on the
  calendar.
- **guide-to-advancement** — get the policy, with citations. Use it for the Eagle
  project approval chain, boards of review, extensions, and anything about the
  18th birthday.
- **`docs/Scouts-BSA-Requirements-2025.pdf`** — the requirement text itself.
  Read it for every requirement you name in the plan; the partials list gives
  you a code like "8d" and nothing else, and "cook one breakfast, one lunch, and
  one dinner for your patrol" is what makes it schedulable.

State the calendar fact and the advancement implication separately. The calendar
shows something is scheduled, not that a Scout attended or that a requirement was
met.

## Writing the plan

Lead with the two or three findings that change what leaders should do. A good
plan has answered: *who is running out of time, what has to start this week, and
who is one meeting away from a rank?*

Suggested shape:

1. **Bottom line** — three findings, at most.
2. **Roster and cohorts** — grouped by working rank, ordered by months to 18.
3. **The clocks** — the multi-week requirements, with the date each cohort has
   to start, and the service-hour and position-of-responsibility gaps.
4. **Saturday at the Shed** — a full session plan for each one in the window.
5. **Meeting-by-meeting plan** — program focus plus conference/board load.
6. **Calendar hooks and gaps** — which event closes which requirement, and what
   has no date at all.
7. **Per-Scout to-do lists** — program work, merit badges, then the collapsed
   meeting line.
8. **Batch opportunities** — ranked by Scouts served.
9. **Leadership to-do list** — ordered by urgency, not by size.
10. **Notes on the source data** — the Star SM Conf defect, anything the parse
    could not resolve, and any figure that is an estimate.

Write plans to `plans/target-eagle-YYYY-MM-DD.md`, dated from the report.

Three things to keep honest: label projected advancement counts as estimates;
when a Scout cannot realistically make the next court of honor, say so and give
the date they can make instead; and when the grid cannot answer something —
which Eagle-required badges remain, for a Scout with surplus electives — say
that it cannot, rather than guessing from the asterisks.
