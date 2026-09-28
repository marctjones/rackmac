# Publishing (epic E22)

_Decided in conversation 2026-09-27/28. Short on purpose: it records decisions and their reasons, not a spec._

## Goal

Make Rackmac a higher-quality publishing tool, primarily **PDF and slides**, with **visible styles** and a
programmable layer that is **accessible to power users but easier than Pollen**. The Racket-hosted publishing
languages (Scribble, Slideshow, Pollen) become editable Rackmac **Languages** with a live preview.

Note the two senses of "Language": in Rackmac it is a document type (Markdown, Racket, Python; E19). Here it also
names the `#lang`s themselves.

## Principles

1. **Content, presentation and output stay separate.** A note is portable Markdown. Presentation is a style sheet
   (data, edited through a visible Styles panel, never hand-typed). Output is a renderer. Programmable structure lives in
   extensions and recipes, not in the note file, so a note still reads the same in any editor.
2. **One layout engine for preview and export** (MDLIB.M3: #401 layout boxes, #402 native PDF renderer), so WYSIWYG
   cannot drift from the printout. Slides are the simpler test of it: fixed frames, no text flowing between pages.
3. **Borrow ideas, not pipelines.** Scribble's cross-references, numbering and indexes; Pollen's source, tree,
   templates, outputs; Slideshow's pict-based slides. Scribble's PDF path needs LaTeX, so it is not the export path.
4. **Documents in these languages are programs.** Previewing runs their code. Preview is therefore explicit, sandboxed
   (time and memory limits), and asks before running a file from an untrusted location. Never auto-run on open.
5. **No new dependency without asking.** Scribble, Slideshow and pict ship with Racket and are already installed.
   Pollen is not installed and is a separate package: detect it like pandoc (#278), never bundle it.

## Order

1. **M1 Scribble** as a Language, with a Preview command. First preview is the built HTML in the default browser,
   rebuilt on save. In parallel, a **spike** on an embedded web view (WKWebView through `ffi/unsafe/objc`, the route
   `rackmac/pasteboard.rkt` already uses). The embedded pane follows only if the spike says go.
2. **M2 Slideshow** as a Language, after a **spike** on capturing a slide file's picts to draw natively on a Rackmac
   canvas. Slide sorter and present mode come after.
3. **M3 Pollen**, optional: detect it, offer `.pmd`/`.pm`/`.p` Languages and a Start Server command, and explain how to
   install it when missing.

## Later, not yet filed

The Styles panel and style-sheet model; Page View (WYSIWYG from the shared engine); no-code components inserted from a
menu (needs an mdlib directive extension: a format commitment to make deliberately); the Racket component layer on the
extension API (E11); page setup, headers and footers; legal formats (numbered paragraphs, pleading paper, Bates
numbering, tables of contents and authorities). Filed when the layout engine is far enough along to plan against.

## Open risks

- A native view embedded in a racket/gui canvas is fiddly; hence the spike.
- Browser preview shows content, not page-accurate layout. That is acceptable for editing a language, not for WYSIWYG.
- Depends on language groundwork still open in E19 (#310 Racket lexer coloring, #315 scoped Run).
