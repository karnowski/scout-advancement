---
name: individual-history
description: Answer questions about a Scout's advancement record — ranks, requirement sign-offs, merit badges and partials, Eagle-required coverage (13 slots; the troop does not count Citizenship in Society), leadership tenure, awards — from the imported TroopMaster "Individual History" data.
---

# Individual history

Answer **"what does the troop's record actually say?"** about one Scout, or
about everyone at once, from the database `import-individual-history` builds.

This is the skill to reach for in a Scoutmaster conference, when a parent asks
what their Scout still needs, when the Advancement Chair is deciding who to put
in front of a board of review, or when someone asks which Life Scouts are short
on their position of responsibility.

**It reports; it does not plan.**  It says what is signed off, what is not, how
many months of credited leadership a Scout has, and which Eagle slots are
filled.  It never decides what a Scout should work on next, in what order, or by
when — that is `generate-advancement-plan`.  Keeping the line sharp is what lets
a plan be checked against the record it came from.

It is also strictly a reader: it never writes to the database and never opens a
PDF.  `import-individual-history` is the only writer.

## Tool

`scripts/history.rb` reads
`../import-individual-history/.cache/individual-history.db`.  It needs the
repo's gems (`bundle install` from the repository root) and no PDF tools at all.

```
ruby scripts/history.rb show     NAME               everything the record holds
ruby scripts/history.rb json     [NAME]             the same, machine-readable
ruby scripts/history.rb needs    NAME [--rank R]    what is unsigned for the next rank, or rank R
ruby scripts/history.rb eagle    [NAME]             the 13 Eagle-required slots
ruby scripts/history.rb por      [NAME]             credited months toward the next rank's position
ruby scripts/history.rb roster                      rank, what each is working on, open count, POR
ruby scripts/history.rb who      LABEL [--rank R]   who still has this requirement unsigned
ruby scripts/history.rb badge    BADGE              who earned it, who started it, who has not
ruby scripts/history.rb partials [NAME] [--stalled DAYS]   open partials, most idle first
ruby scripts/history.rb awards   [NAME]             special awards, National Outdoor Award
                                                    segments, training, Order of the Arrow
```

The per-Scout commands (`json`, `eagle`, `por`, `partials`, `awards`) cover
**everyone imported** when the name is left off, which is usually how a
troop-wide question gets answered.

`NAME` matches `"Rivera, Sam"`, `"Sam Rivera"`, `Rivera`, or `Sam`.  A name that
matches two Scouts is an error naming both, never a guess — an answer given
about the wrong Scout is worse than no answer.

If nothing has been imported the script says so and gives the command to run.

## Start by checking the data is fresh

Every answer here is only as current as the report it came from, and freshness
is **per Scout** — a report run for one patrol does not refresh anyone else.
`roster` prints each Scout's report age and marks anything over 30 days
`STALE`; `show`, `needs`, and `eagle` carry the same note in their header.

A stale record does not look stale in an answer.  It looks like a Scout who has
not done the work — confidently listing requirements they finished last month.
When the note appears, re-run the Individual History report and import it before
answering.

## Reading the answers

- **`[ ]` means the report printed `__/__/__`** — the troop's record positively
  says the requirement is not signed off.  That is different from a requirement
  the report never showed at all, which simply is not there.  Never report the
  second as though it were the first.
- **A rank with nothing listed has been earned.**  The report prints
  requirement blocks only for ranks not yet earned.
- **`N more merit badges` is a count of unfilled slots**, not a named
  requirement.  Which badges fill them is the Scout's choice, within the
  Eagle-required list.
- **`who` spans every unearned rank at once.**  Because the report prints a
  block for each of them, a Scout-rank Scout matches "Position of
  Responsibility" three times — at Star, at Life, and at Eagle.  The rank column
  says which; `--rank Star` narrows it.
- **`partials` reports idle time, not expiry.**  A partial does not lapse on a
  schedule — it is good until the Scout turns 18, though a requirement *year*
  that has since changed is a real complication.  `idle 592d` means nobody has
  recorded progress in that long, which is worth a conversation, not a deadline.
- **A partial's `remarks` line is the Advancement Chair's own note**, carried
  through verbatim from the report — "Completed one ride for 6Bd at WinterBlast
  26".  It often says the thing the percentage does not.
- **Special awards, National Outdoor Awards, and training courses are three
  separate lists**, because the report keeps them separate.  The "NOA Camping
  Gold" under Special Awards is the award; the "Camping" under National Outdoor
  Awards is the segment count behind it.  `awards` rolls all three up across the
  troop, plus Order of the Arrow standing, and counts *Scouts* rather than rows
  — a Scout can hold the same award twice.

## Citizenship in Society is not Eagle-required here

**The troop counts 13 Eagle-required slots, not 14.**  Citizenship in Society
counts toward the 21 merit badges Eagle asks for; it fills no required slot.

This is a decision of the troop's, and it departs from the printed book.
**Scouts BSA Requirements 2025 lists Citizenship in Society as (d) of 14 at
Eagle requirement 3**, so `scout-req` will quote 14 and is not wrong to — the
2026 change list covers merit badge *requirements* only and is silent on the
rank by construction.  When it matters, say which basis an answer is on.

What the decision rests on:

- Every Eagle-remaining figure TroopMaster prints on the troop's whole-troop
  report reproduces exactly as `13 - filled`, with CiS dropped from both the
  slot list and the Scout's filled count.  Nothing reproduces them at 14.
- CiS is the only badge on that report that ever carries `#`, and the only
  Citizenship badge that never carries `*`.
- With CiS dropped, the report's stars and `EAGLE_SLOTS` agree exactly: every
  starred badge is one of the 13 slots' alternates, and nothing outside them is
  starred.

`eagle` still prints TroopMaster's own figure beside its own.  The two now
**agree for every Scout**, so that line is a guard: if it ever reports a
mismatch, either TroopMaster's Eagle-required list or `EAGLE_SLOTS` has moved,
and neither number should be trusted until you know which.

## Eagle coverage is computed from the badge names, not from the star

`eagle` reports the **13 Eagle-required slots**, and three of them are
OR-groups: Emergency Preparedness OR Lifesaving; Environmental Science OR
Sustainability; Swimming OR Hiking OR Cycling.  Any one alternate fills its
slot, so 13 slots are not 13 badges, and counting a Scout's Eagle-required
badges overstates what is left.  The line names whichever alternate the Scout
actually holds.

**Do not answer this question from the `eagle_required` flag in the database**,
even though it now agrees with the slot list.  On the current report every
starred badge is one of the 13 slots' alternates and nothing outside them is
starred — but the OR-groups mean a count of flags is not a count of slots, and
**a badge the report never names carries no flag at all**: an Eagle-required
badge a Scout has not started simply is not in the rows.  `eagle` matches names
against the slot list for both reasons.

## Position of responsibility

`por` answers "has this Scout served long enough yet", and two things about it
are easy to get wrong by hand:

- **Time counts only for the rank being worked on.**  The book reads "While a
  Star Scout, serve actively in your troop for six months."  Service before the
  Scout earned their current rank counts toward the rank it was served under,
  not the next one — so a Scout with years of leadership can legitimately show
  zero months toward Life.  Tenure is clipped to start at their own rank date.
- **Overlapping terms are one stretch of calendar time, not two.**  A Scout
  holding Bugler and Patrol Leader over the same six months has served six
  months, not twelve.  The script merges the intervals.

Positions marked "not credited toward rank" (`#` on the report) are excluded,
and the book agrees: a footnote to Star, Life, and Eagle says assistant patrol
leader is not an approved position of responsibility.

The month thresholds the script prints against (4 for Star, 6 for Life, 6 for
Eagle) are **a threshold, not the requirement**.  Whether a Scout has "served
actively" is a judgment for the Scoutmaster, and the governing text comes from
`scout-req`:

    ruby ../scout-req/scripts/req.rb show "Life"

Questions about *how* the determination is made — what counts as active, what
to do about a Scout who was elected but did not serve — are
`guide-to-advancement`.

## Requirement text comes from elsewhere

The labels this skill prints — `4c. Tell How to Prevent Injury`, `Position of
Responsibility` — are **TroopMaster's abbreviations, not the requirements.**
They are far too short to plan from and are not maintained against the book.
Never quote one as though it were requirement text.

The text that governs comes from `scout-req`, which is the only reader of the
requirements book and the only thing that knows the 2025 printing's limits:

    ruby ../scout-req/scripts/req.rb show "First Class"
    ruby ../scout-req/scripts/req.rb show "Personal Management"

This matters most on partials.  Each carries the requirement **year** the Scout
started under (`Personal Management (2019)`), which is often not the current
one, and 65 of the book's 139 merit badges changed effective Jan. 1, 2026 — so
say which year a partial is under, and check the current text before telling a
Scout what is left.

Who counsels a badge comes from `mbc`; when things are scheduled comes from
`troop-calendar`.

## Privacy

**This repository is public and everything here describes minors** — names, and
on `show` also email, phone, and date of birth.

The database lives in the importing skill's `.cache/` and the report in
`reports/`; `.gitignore` covers both.  Names are fine in a session and in
answers to the Advancement Chair.  They never reach a tracked file, a commit
message, a branch name, or a PR description.  The names used in this file are
invented.

## Facts the script depends on

- **The `eagle_required` flag cannot answer Eagle coverage** — see above.  It is
  displayed, never counted.
- **`EAGLE_SLOTS` duplicates the table in `mbc.rb` on purpose.**  Both are match
  keys against badge names — one for counselor coverage, one for badge
  coverage.  Keep the two in step; neither is a copy of the book, and **both
  now carry 13 slots** with Citizenship in Society removed.
- **`normalize` must stay identical** to the one in `req.rb`, `mbc.rb`,
  `inventory.rb`, and `individual_history.rb`.  Dropping "and"/"the" is what
  makes TroopMaster's `Citizenship In Nation` resolve against the book's
  `Citizenship in the Nation`, and its `Fly Fishing` against `Fly-Fishing`.
- **Tenure is a union of intervals, clipped to the Scout's rank date** — both
  halves matter, and the troop's current report exercises both.
- **Order of the Arrow is columns on `scouts`, not a table**, and the report
  prints every OA field whether or not it has a value — so a Scout who is not in
  the Order stores as all-NULL rather than as no row.  Membership is "some step
  has a date", never "a row exists".
- **Months are reported as days ÷ 30.44**, to one decimal.  It is a measure of
  elapsed time, not a count of calendar months, and it is there to show whether
  a Scout is close — not to settle a sign-off.
