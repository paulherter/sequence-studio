---
title: Roadmap
chapter: roadmap
order: 1
code: ROADMAP.md, scripts/check-roadmap.py
---

## For users

Everything that is still planned, in one list sorted by priority. The list is generated from `ROADMAP.md` in the repository; filter it by area or status below.

{{roadmap}}

## For developers

`ROADMAP.md` is the only source. Rules for the table are enforced by `scripts/check-roadmap.py`: one table with the columns ID, Priority, Area, Item and Status; IDs `SQ-nnn` are unique, ascending and never reused; priority 1 to 7; sorted by priority with finished items last in their group; no links or line breaks inside cells. The branch that starts or finishes an item changes its status.

## For AI agents

- Source: `ROADMAP.md`. Parser and rules: `scripts/check-roadmap.py` (`python3 scripts/check-roadmap.py`).
- Status values: `in progress`, `not started`, `done`. Areas are a fixed set listed in `scripts/check-roadmap.py` (`AREAS`).
- Never reuse an ID. Update the "Last reviewed" date when you change the table.
- The wiki page is rendered from the file by `scripts/build-wiki.py`; `scripts/deploy-website.py --check` fails when the built page and the file disagree.
