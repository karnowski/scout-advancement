---
name: scout-req
description: Look up the official text of a Scouts BSA rank, merit badge, or award requirement in Scouts BSA Requirements 2025.
---

# Scouts BSA Requirements 2025

Quote the official text of a rank, merit badge, or award requirement from
`references/Scouts-BSA-Requirements-2025.pdf` — the 2025 requirements book.

**Never answer a requirement question from memory.** Requirements are
year-versioned and change every January; what you remember is a mixture of
printings. Everything you say about what a Scout must *do* has to come from text
this skill actually retrieved, and it has to carry the year it came from.

## Scope

This book is *what* a Scout must do. For *how* advancement is administered —
boards of review, counselor approval, appeals, extensions — the source is the
Guide to Advancement, and the `guide-to-advancement` skill answers from it.
Questions about a specific Scout's progress belong to `target-first-class` or
`target-eagle`; this skill is the requirement text those plans cite, and they
call it rather than reading the book themselves.  Scripts live in sibling
directories, so they reach each other by relative path —
`ruby ../scout-req/scripts/req.rb show NAME` from any skill directory.

## Tool

`scripts/req.rb` indexes the book and prints entries out of it. It builds its
cache automatically on first use (needs `pdftotext` and `pdftohtml`;
`brew install poppler`).

```
ruby scripts/req.rb verify                            # parse check — run this first
ruby scripts/req.rb show NAME [--kind rank|badge|award]
ruby scripts/req.rb check [NAME...] [--kind K]        # or names on stdin, one per line
ruby scripts/req.rb list [--kind K] [--letter A] [--pamphlet-year YYYY]
ruby scripts/req.rb search PATTERN [--kind K] [--context N] [--max N]
ruby scripts/req.rb page PRINTED_PAGE [--to PRINTED_PAGE]
ruby scripts/req.rb updates [NAME]
ruby scripts/req.rb build [--force]
```

- `show` takes a name in any reasonable spelling — case, punctuation,
  ampersands, and "and"/"the" are all folded, so `first-class`, `First Class`,
  and `FIRST CLASS` are the same query. It prints the entry's full requirement
  text with the printed page it came from.
- `check` is `show`'s guard without the text: it prints **nothing** for a name
  this book covers cleanly, a banner for one it does not, and exits 3 if any
  name was flagged. It takes many names at once — as arguments or one per line
  on stdin — which is what makes checking a whole TroopMaster report affordable.
- `list` is the index: 9 ranks, 139 merit badges, 26 awards.
- `search` is a case-insensitive regex over requirement text, and reports which
  entry each hit falls in — the way to answer "which badges require a swim
  test?" or "where does 'Scout spirit' appear?".
- `page` takes **printed** page numbers (the number at the foot of the page),
  not PDF page numbers. Results show both; use the PDF number if you need the
  Read tool to look at a page image.
- `updates` lists the 42 merit badges whose requirements changed in the 2025
  printing, and which numbered requirements changed.

## ⚠ A merit badge this book does not carry

This is the failure this skill exists to prevent. A Scout handed 2025 text for a
badge that changed in 2026 does months of the wrong work, and nothing about the
answer looks wrong — it is fluent, specific, and cited. There is no way to catch
it downstream, so it has to be caught here.

**`show` and `check` exit `3` and print a full-width banner when the answer
would need requirements this book does not carry.** That happens three ways:

1. **The name is not in the book at all** — a merit badge introduced or renamed
   after the 2025 printing, or a typo. The banner lists the closest names in the
   book so you can tell the two apart.
2. **The name is recorded in `data/beyond-2025.json`** as new since 2025.
3. **The badge is in the book but that file records it as revised since 2025** —
   `show` still prints the 2025 text, under a `SUPERSEDED` banner; `check`
   prints the banner alone.

**When you get exit 3, stop and announce it.** Lead your answer with it; do not
bury it under the requirement text or a summary. Say plainly that this skill
cannot supply those requirements and that they must come from
`www.scouting.org/meritbadges`. Do **not** fill the gap from memory, do **not**
offer the 2025 text of a superseded badge as "close enough", and do **not** let
a plan, to-do list, or Scout assignment be built on it.

Run every badge name you get from somewhere else — a TroopMaster report, the
Advancement Chair, a Scout — through `check` before planning around it. That is
how a 2026 badge actually reaches this skill, and `check` is silent unless
something is wrong, so the whole list costs one call:

```
ruby ../target-eagle/scripts/te.rb badges REPORT.pdf --partials PARTIALS.pdf \
  | ruby scripts/req.rb check
```

### Keeping `data/beyond-2025.json` current

A name the book has never heard of announces itself with no help. The case that
needs the file is the one nothing local can reveal: **a badge that is in the
2025 book but whose requirements changed afterward.** Recording it there turns a
silently-wrong answer into a loud one.

Entries go in only when someone has checked `www.scouting.org/meritbadges`,
never from recollection — the file shipped empty for that reason, and it holds
only what has been confirmed there since.  Its header documents the fields.  If
the Advancement Chair tells you a badge has changed, offer to add it; cite where
the change was confirmed in the `source` field.

## Workflow

1. **`verify` first** if you have not run it this session, and never quote from
   a parse that fails it (see below).
2. **`check` any names that came from a report or a person** before you look
   anything up.  One call, silent unless something is wrong.
3. **Find the entry.** `show NAME` for a specific rank, badge, or award; `list`
   to see what exists; `search` when the question is about a phrase rather than
   an entry ("which badges need a counselor-approved project?").
4. **Read the whole entry, not one requirement.** Requirements reference each
   other constantly — First Class 6a needs the swimmer test defined in Swimming,
   Second Class 7a starts only after Tenderfoot 6c. A requirement quoted out of
   its entry loses the conditions on it.
5. **Answer, quoting verbatim and citing the printed page and the year.**

## Answering

- **Quote requirement text exactly.** Never paraphrase inside quotation marks,
  and never renumber. The numbering *is* the requirement's identity — "Tenderfoot
  6b" is how it appears in TroopMaster, on a blue card, and in a Scout's
  handbook.
- **Cite the source and the year every time**: *Scouts BSA Requirements 2025,
  printed p. 13*. `show` prints exactly this line at the end of its output.
- **Carry the option words through.** "Do TWO of the following", "Do ONE of the
  following (a or b)", "with your counselor's approval" — these decide how much
  work a requirement actually is, and dropping them changes the answer.
- **Say when a requirement has a clock.** Anything stating a number of days,
  weeks, nights, or hours cannot be compressed into a meeting, and that is
  usually what the Advancement Chair is really asking about.
- **Note recent changes.** `show` flags a badge listed in the 2025 printing's
  update list. A Scout who started before Jan. 1, 2025 may finish under the old
  requirements — that rule is in the Guide to Advancement, so hand the question
  to `guide-to-advancement` rather than ruling on it here.

### No one may add to or subtract from requirements

No council, district, unit, or individual may change advancement requirements
(front matter, printed p. 2, with limited exceptions for members with special
needs — the two "Alternative Requirements" entries and Section 10 of the Guide).
Raise this when a question is really about the troop adding its own expectation
on top of a requirement.

## Facts about the book the script depends on

All verified against `references/Scouts-BSA-Requirements-2025.pdf` (308 pages).

- **Never trust a parse that fails `verify`.** This book has no section numbers
  and no tally to check against, so a heading the script missed does not surface
  as an error — it surfaces as the *neighbouring* badge's requirements printed
  under the wrong name, which reads as a perfectly good answer. `verify`
  reconciles the indexed badges against the **Merit Badge Library** on the last
  printed page, the book's own independent list of all 139, and additionally
  checks that badges run alphabetically under the right A–Z tab, that the nine
  rank entries are exactly right, and that every heading was located in the text.
- **Headings are found by font size, not by wording.** Every entry heading —
  rank, merit badge, and award alike — is 21pt RockwellStd, and nothing else in
  the book is. There is no other signal: a heading is an unnumbered line of plain
  words, indistinguishable in `pdftotext` output from the many unnumbered lines
  inside requirements. Matching heading text against a hardcoded badge list was
  the first attempt, and it silently missed every heading that wraps.
- **The `pdftohtml -xml` / `pdftotext` split is measured.** The XML carries font
  size and glyph position, which is the entire basis of the index; plain
  `pdftotext` (no `-layout` — this book is single-column) gives clean reading
  order for the requirement text. Neither does both jobs well.
- **Printed page + 2 = PDF page**, measured from the footers rather than assumed.
- **Page 277 carries an off-canvas duplicate of the 50-Miler Award** at
  left=-408, InDesign overflow that never printed. It must be filtered out or
  the index gains a phantom entry.
- **The book alphabetizes without "the"** — the Citizenship badges are filed
  Community, Nation, Society, World — and the Merit Badge Library abbreviates
  ("Pulp & Paper", "Signs, Signals, Codes"). Name matching folds both, which is
  also why loose user spellings resolve.

**Read these before changing the parser.** Each was established by getting it
wrong first; the code shows what is done, not the alternative that was tried and
silently produced garbage.
