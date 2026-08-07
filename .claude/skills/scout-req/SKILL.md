---
name: scout-req
description: Look up the official text of a Scouts BSA rank, merit badge, or award requirement in Scouts BSA Requirements 2025, with the merit badge changes effective Jan. 1, 2026.
---

# Scouts BSA requirements

Quote the official text of a rank, merit badge, or award requirement from two
documents, and never from either alone:

- `references/Scouts-BSA-Requirements-2025.pdf` — the 2025 requirements book,
  read by `scripts/req.rb`. The base text for everything.
- `references/Major-Requirement-Changes-as-of-1_1_2026.pdf` — Scouting America's
  change list published 11/14/2025, read by `scripts/changes.rb`. **65 of the
  book's 139 merit badges changed effective Jan. 1, 2026**, and this carries the
  updated text of every changed requirement.

**Never answer a requirement question from memory.** Requirements are
year-versioned and change every January; what you remember is a mixture of
printings. Everything you say about what a Scout must *do* has to come from text
this skill actually retrieved, and it has to carry the year it came from.

**Nearly half the merit badges changed for 2026.** Quoting the 2025 book on one
of them is the most likely way to get an answer wrong here, and `req.rb show`
prints the 2026 replacement text after the 2025 entry precisely so that cannot
happen quietly. If you find yourself quoting a badge's requirements without
having seen either "0 changed for 2026" or a change table, stop and check.

## Scope

These two documents are *what* a Scout must do. For *how* advancement is administered —
boards of review, counselor approval, appeals, extensions — the source is the
Guide to Advancement, and the `guide-to-advancement` skill answers from it.
Questions about a specific Scout's progress belong to `target-first-class` or
`target-eagle`; this skill is the requirement text those plans cite, and they
call it rather than reading the book themselves.  Scripts live in sibling
directories, so they reach each other by relative path —
`ruby ../scout-req/scripts/req.rb show NAME` from any skill directory.

## Tools

Two scripts, one per document. Both build their caches automatically on first
use (`req.rb` needs `pdftotext` and `pdftohtml`, `changes.rb` needs `pdftotext`;
`brew install poppler`).

`scripts/req.rb` indexes the 2025 book and prints entries out of it:

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

`scripts/changes.rb` owns the 2026 change list. `req.rb` consults it on every
`show` and `check`, so you rarely need to call it directly — reach for it when
the question is about the changes themselves:

```
ruby scripts/changes.rb verify                        # parse check — run this first
ruby scripts/changes.rb list [--rows]                 # the 65 changed badges
ruby scripts/changes.rb show NAME                     # the change table for one badge
ruby scripts/changes.rb check [NAME...]               # which of these changed; silent if none
ruby scripts/changes.rb build [--force]
```

- `show` takes a name in any reasonable spelling — case, punctuation,
  ampersands, and "and"/"the" are all folded, so `first-class`, `First Class`,
  and `FIRST CLASS` are the same query. It prints the entry's full requirement
  text with the printed page it came from.
  When the badge changed for 2026, the header says so and the change table
  follows the 2025 text, so a single `show` is the whole answer.
- `check` is `show`'s guard without the text: it prints **nothing** for a name
  that is clean on both counts, a banner for one neither document can answer
  for, a `note:` for one that changed in 2026, and exits 3 only for the banner.
  It takes many names at once — as arguments or one per line on stdin — which is
  what makes checking a whole TroopMaster report affordable.
- `list` is the index: 9 ranks, 139 merit badges, 26 awards.
- `search` is a case-insensitive regex over requirement text, and reports which
  entry each hit falls in — the way to answer "which badges require a swim
  test?" or "where does 'Scout spirit' appear?".
- `page` takes **printed** page numbers (the number at the foot of the page),
  not PDF page numbers. Results show both; use the PDF number if you need the
  Read tool to look at a page image.
- `updates` lists the 42 merit badges whose requirements changed **in the 2025
  printing** — that book's own front matter, history rather than news. What
  changed *since* is `changes.rb list`. Do not confuse the two.

## ⚠ The three answers, and which one you got

A Scout handed the wrong year's text does months of the wrong work, and nothing
about the answer looks wrong — it is fluent, specific, and cited. Nothing
downstream can catch it, so it is caught here, and there are exactly three
outcomes.

**1. Clean.** The 2025 book carries it and nothing changed for 2026. Quote it,
cite the book and the year, exit 0.

**2. Changed effective Jan. 1, 2026 — answerable.** 65 merit badges. `show`
flags the count in its header and prints the change table after the 2025 text;
`check` prints a `note:` naming them. **Exit stays 0** — the updated text is
right here, so this is not a failure, it is the answer.

Say the year on every requirement you quote for one of these. Where the change
table gives 2026 text, that is what governs; the 2025 book covers the rest of
the badge. Never present the 2025 text of a changed requirement as current, and
never say "the rest is unchanged" — see the limits below.

**3. Neither document carries it — exit `3`.** Two ways:

  - **The name is not in the book at all** — a merit badge introduced or renamed
    after the 2025 printing, or a typo. The banner lists the closest names in the
    book so you can tell the two apart.
  - **The name is recorded in `data/beyond-2025.json`** as new, renamed, or
    discontinued since 2025.

**When you get exit 3, stop and announce it.** Lead your answer with it; do not
bury it under the requirement text or a summary. Say plainly that this skill
cannot supply those requirements and that they must come from
`www.scouting.org/meritbadges`. Do **not** fill the gap from memory, do **not**
offer the 2025 text as "close enough", and do **not** let a plan, to-do list, or
Scout assignment be built on it.

Run every badge name you get from somewhere else — a TroopMaster report, the
Advancement Chair, a Scout — through `check` before planning around it. That is
how a 2026 badge actually reaches this skill, and `check` is quiet unless
something needs saying, so the whole list costs one call:

```
ruby ../target-eagle/scripts/te.rb badges REPORT.pdf --partials PARTIALS.pdf \
  | ruby scripts/req.rb check
```

## ⚠ What the 2026 change list does *not* settle

Say these out loud when they matter; do not let them be inferred.

- **It is the *major* changes.** Scouting America published it as such, not as
  the 2026 requirements book. A requirement it does not mention is *probably*
  unchanged, but the document cannot prove it. Never tell the Advancement Chair
  "everything else is the same" — say the 2025 book plus the published major
  changes, which is what you actually have.
- **Merit badges only.** Every row names a merit badge; no rank and no award
  appears. That is not evidence ranks were untouched for 2026, only that this
  document does not cover them. A rank question is answered from the 2025 book
  with that caveat stated.
- **Dated 11/14/2025.** Anything published after that is not in it.
- **A Scout who started earlier may finish under the old requirements.** That
  rule is in the Guide to Advancement, so hand the question to
  `guide-to-advancement` rather than ruling on it here. It matters far more now
  than it did: 65 badges' worth of Scouts are mid-badge across the boundary.

### Keeping `data/beyond-2025.json` current

A name the book has never heard of announces itself with no help, and a badge
merely *revised* for 2026 is now the change list's job — all 65 of them, with
the text. **Do not hand-enter a revised badge here:** an entry in this file means
"this skill cannot supply these requirements" and exits 3, which is wrong for a
badge whose 2026 text this skill has.

What is left for the file is what no local document reveals: a badge introduced,
renamed, or discontinued after the 2025 printing, or one revised by something
published after the change list's 11/14/2025 date.

Entries go in only when someone has checked `www.scouting.org/meritbadges`,
never from recollection.  Its header documents the fields.  If the Advancement
Chair tells you a badge has changed, check `changes.rb show NAME` first — it may
already be covered — and if it is not, offer to add it, citing where the change
was confirmed in the `source` field.

## Workflow

1. **`verify` first** if you have not run it this session — both scripts — and
   never quote from a parse that fails it (see below).
2. **`check` any names that came from a report or a person** before you look
   anything up.  One call, quiet unless something needs saying.
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
  printed p. 13*, or *Major Requirement Changes as of 1/1/2026, published
  11/14/2025* for a requirement out of the change table. `show` prints exactly
  these lines at the end of its output. A quote with no year is the bug this
  skill exists to prevent.
- **Carry the option words through.** "Do TWO of the following", "Do ONE of the
  following (a or b)", "with your counselor's approval" — these decide how much
  work a requirement actually is, and dropping them changes the answer.
- **Say when a requirement has a clock.** Anything stating a number of days,
  weeks, nights, or hours cannot be compressed into a meeting, and that is
  usually what the Advancement Chair is really asking about.
- **Note recent changes.** `show` flags both — what the 2025 printing changed
  when it was printed, and what changed effective Jan. 1, 2026. Keep them
  apart when you report them; they are different years and different documents.

### No one may add to or subtract from requirements

No council, district, unit, or individual may change advancement requirements
(front matter, printed p. 2, with limited exceptions for members with special
needs — the two "Alternative Requirements" entries and Section 10 of the Guide).
Raise this when a question is really about the troop adding its own expectation
on top of a requirement.

## Facts about the book `req.rb` depends on

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

## Facts about the change list `changes.rb` depends on

All verified against `references/Major-Requirement-Changes-as-of-1_1_2026.pdf`
(38 pages, 792×612pt landscape, Acrobat PDFMaker for Word). The document is one
long three-column table: MERIT BADGE | UPDATED REQUIREMENT | ORIGINAL
REQUIREMENT, alphabetical from Archaeology to Wilderness Survival, one row per
changed requirement.

- **Never trust a parse that fails `verify`.** A row boundary in the wrong place
  does not read as an error — it reads as one badge's updated text filed under
  the requirement number of the row above it. There is no tally row, so `verify`
  builds one: every word inside the table must be claimed by exactly one row,
  every page's first row must be the repeated column header, every badge name
  must resolve against `req.rb list --kind badge`, the badges must run
  alphabetically in contiguous runs, and eleven canary cells must survive whole.
- **Row and column boundaries come from the table's drawn rules, never the
  text.** Word emits each cell border as a 0.48pt-high filled rectangle exactly
  as wide as its column, and `pdf-reader` reports them. Every text-based rule
  tried first was wrong: the vertical gap *between* rows (9.0pt) is smaller than
  the gap *inside* one (9.1pt), and "a numbered line at the cell's base indent"
  over-detects by a quarter, because sub-items are numbered and sit at base
  indent too (Athletics 5 runs "1. Left-side layup" through "8. Anywhere along
  the three-point line", none of which starts a row).
- **A border is *black*; cell shading is the same shape and is not.** Word paints
  each shaded cell as a stack of hairline strips at text-line pitch — peach
  behind the name column, light blue behind the updated one. On page 29 that put
  ten false boundaries through Search and Rescue requirement 3 and shattered it.
  Colour is the only thing that separates them.
- **Row boundaries are the black rules the *name* and *updated* bands agree on,
  not all three.** The original column's cell can be merged down across two rows
  and then carries no rule between them (Veterinary Medicine 6(a)/6(b), page 36);
  requiring all three welds those two rows into one.
- **The badge name cell is vertically centered,** level with the middle of its
  row rather than its first line. That is why `pdftotext -layout` is useless here
  — it interleaves the name into the middle column ("Athletics   or event.").
- **Slice columns per `<word>`, never per `<line>`.** `pdftotext -bbox-layout`
  merges words from different cells into one line when they share a baseline:
  "Citizenship in the Community" arrives fused to "(2) Fire station, police
  station, and hospital nearest your home".
- **A row can outrun its page.** Plant Science requirement 8 fills page 21 and
  gets no closing rule; the vertical borders are what close it. Page 22 is the
  blank remainder. Without this the whole cell vanishes, and a vanished cell
  reads as "that badge had fewer changes".
- **An empty cell is the content.** Empty ORIGINAL means the requirement is new
  (Traffic Safety 5 and 6); empty UPDATED means it was deleted (Engineering 9).
  A cell holding no letter or digit is empty whatever glyphs it has — Engineering
  leaves a lone "." behind, and reading that turns a deletion into a revision.
- **Strikethrough is drawn, not encoded, and is deliberately not recovered.** The
  ORIGINAL cell is the 2025 text either way, and the pairing carries the meaning.
  Red = added text *is* recoverable (`pdftohtml -xml` gives `color="#ff0000"` per
  fontspec) if word-level change marking is ever wanted.

**Read these before changing either parser.** Each was established by getting it
wrong first; the code shows what is done, not the alternative that was tried and
silently produced garbage.
