---
name: guide-to-advancement
description: Answer questions about how Scouting America (BSA) advancement is administered, based on Guide to Advancement 2025.
---

# Guide to Advancement 2025

Answer advancement policy and procedure questions from the Guide to Advancement
2025 (`docs/guide-to-advancement-2025.pdf`), quoting the text that supports the
answer and citing exactly where it comes from.

**Never answer from memory.** Scouting requirements and procedures change yearly,
and the Guide's wording is the thing being asked about.  Every claim in the answer
must come from text this skill actually retrieved.

## Scope

The Guide governs *how* advancement is administered — procedures, roles, and
policy.  For *what* a Scout must do to earn a rank or merit badge, the source is
`docs/Scouts-BSA-Requirements-2025.pdf` instead.  If a question turns on the text
of a requirement rather than on how advancement is run, say so and point to the
requirements book.

## Tool

`scripts/gta.rb` searches a cached text extraction of the PDF.  It builds the
cache automatically on first use (needs `pdftotext`; `brew install poppler`).

```
ruby scripts/gta.rb search "board of review" [--context 3] [--max 25]
ruby scripts/gta.rb section 8.0.1.1
ruby scripts/gta.rb page 55 [--to 57]
ruby scripts/gta.rb toc [--section 8]
ruby scripts/gta.rb build [--force]
```

- `search` takes a case-insensitive Ruby regex and reports each hit with the
  section it falls in.
- `section` prints one numbered section, from its heading to the next.
- `page` takes **printed** page numbers (the number at the foot of the page), not
  PDF page numbers.  Every result shows both; use the PDF number if you need the
  Read tool to look at the page image.
- `toc` lists all 224 sections with their printed pages; `--section 8` restricts
  to one top-level section.

## Workflow

1. **Orient.** `toc --section N` if you know roughly where the topic lives; the
   top-level sections are 1 Introduction (p. 6), 2 Advancement Defined (p. 8),
   3 Guidelines for Advancement Committees (p. 10), 4 The Mechanics of
   Advancement (p. 14), 5 Special Considerations (p. 32), 6 Electronic
   Advancement Reporting (p. 38), 7 The Merit Badge Program (p. 40), 8 Boards of
   Review (p. 54), 9 The Eagle Scout Rank (p. 64), 10 Advancement for Members
   With Special Needs (p. 78), 11 Appendix (p. 85).
2. **Find.** `search` with a distinctive phrase.  Search the Guide's own wording,
   not paraphrase — try several phrasings, and prefer terms of art ("unit leader",
   "board of review", "counselor") over colloquial ones.
3. **Read in context.** Pull the whole `section` around a promising hit.  A search
   hit alone is not enough to answer from; the qualifying sentence is often in a
   neighbouring paragraph.
4. **Follow cross-references.** The Guide cites itself constantly ("See also
   8.0.1.5.").  Read what it points to before answering.
5. **Answer.**

## Answering

Structure the answer as:

- **The direct answer**, in a sentence or two.
- **The supporting text, quoted verbatim.**  Quote enough to carry the reasoning
  on its own — the exact sentence that decides the question, plus any sentence
  that qualifies it.  Never paraphrase inside quotation marks.
- **The citation** for each quote: section number, section title, and printed
  page, e.g. *8.0.1.1 "Not a Retest or 'Examination'", printed p. 55*.
- **Related sections** worth reading, cited the same way.

### Mandated vs. recommended

The Guide assigns specific weight to its verbs, and the answer must preserve it
(front matter, "Mandated Procedures and Recommended Practices", printed p. 2):

- **must** — mandated; no council, committee, district, unit, or individual may
  deviate without written permission from the National Program Committee or their
  designee.
- **should** — a highly recommended best practice.
- **may** / **can** — an option or guideline.

Say which one applies.  "The Guide says boards *should* do X" and "boards *must*
do X" are different answers, and the distinction is usually the point of the
question.

Related: no one may add to or subtract from advancement requirements, with
limited exceptions for members with special needs (front matter, "Policy on
Unauthorized Changes to Advancement Program", printed p. 2, and Section 10).
Raise this when a question is really about a unit adding its own expectations.

### When the Guide does not answer it

Say so plainly rather than reasoning from general Scouting knowledge.  Report what
was searched, quote the nearest relevant text, and note the Guide's own guidance
for uncovered issues (1.0.1.0 "How to Approach Issues Not Covered in the Guide to
Advancement", printed p. 6) — which directs questions to the local district or
council advancement chairs or staff advisors.

Distinguish these three cases explicitly, because they lead to different actions:
the Guide answers it; the Guide is silent and the decision is local; the Guide
addresses something adjacent but not this.
