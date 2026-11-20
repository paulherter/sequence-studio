# Wiki source

The pages in this folder are the source of the wiki on the website. `scripts/build-wiki.py` turns them into static HTML
(`website/wiki/`), and `scripts/deploy-website.py` runs it before every check and upload.

## Page template

```
---
title: Page title
chapter: getting-started
order: 1
code: crates/sq-export, crates/sq-core-project/src/export_settings.rs
---

## For users
What the feature does and how to use it. Confirmed in the app or the code.

## For developers
Crates, data flow, tests and extension points.

## For AI agents
Structured facts: inputs and outputs, invariants, file paths, commands to run.
```

- `chapter` is one of the slugs in `CHAPTERS` in `scripts/build-wiki.py`; `order` sorts pages inside a chapter.
- `code` lists the repository paths the page describes (files or folders, comma separated). `scripts/check-wiki.py`
  fails when one of them changed since the last public release and the page did not.
- Every page has the three sections in this order. An unfinished section holds `<!-- TODO(wiki): ... -->`; the page
  shows "Not written yet" and `scripts/check-wiki.py --todos` counts the markers.
- Links to other pages use the file name (`[Export](export.md)`); links to other repository files become GitHub links.
- Markdown subset: headings, paragraphs, lists, tables, fenced code, block quotes, bold, italic, code, links, images.
  `{{roadmap}}` (only in `roadmap.md`) inserts the roadmap table from `ROADMAP.md`.
- American English, neutral maintainer text. Every fact is read from the code.
