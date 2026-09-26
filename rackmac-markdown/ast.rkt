#lang racket/base
;; The data model (design §1.2): immutable, transparent nodes with spans and tokens on every
;; node, plus the token-role vocabulary and the extension-set used to switch extensions on/off.
;; Inline nodes (mdlib-inlines, inlines.rkt) hang off paragraphs and headings through an
;; inline-cell (below); `block-inlines` in main.rkt is the accessor consumers use.
(require racket/promise)
(provide (all-defined-out))

;; --- Tokens -----------------------------------------------------------------------------------

;; The closed set of markup-token roles (design §1.2). Exported as a list so tests can check
;; coverage as new phases add tokens; mdlib-blocks only emits the block-level subset.
(define token-roles
  '(heading-marker setext-underline quote-marker bullet ordered-marker task-marker
    fence fence-info code-indent
    emph-delim strong-delim strike-delim code-delim
    link-open link-close link-dest-open link-dest link-title link-dest-close link-label
    refdef-label refdef-dest refdef-title
    autolink-bracket escape entity hard-break-marker
    table-pipe table-delim-row
    wiki-open wiki-pipe wiki-close tag-hash front-matter-fence
    html))

(define (token-role? sym) (and (memq sym token-roles) #t))

(struct token (role start end) #:transparent)

;; --- Blocks -------------------------------------------------------------------------------------

(struct block (start end tokens) #:transparent)

(struct document block (text children refmap line-index extensions) #:transparent)
(struct paragraph block (segments inlines) #:transparent)                 ; leaf
(struct heading block (level setext? keyword segments inlines) #:transparent) ; leaf
(struct thematic-break block () #:transparent)                            ; leaf
;; lines: list of (list line-start line-end virtual-indent), one per content line, the source
;; slice for each with `virtual-indent` spaces of tab-partial-consumption prepended (§1.3).
(struct code-block block (fenced? fence-char info lines) #:transparent)   ; leaf
;; kind: 1..7 (spec, "HTML blocks"); lines: same shape as code-block's, since a container prefix
;; (block quote, list) can still precede an HTML block's lines and must not appear in its output.
(struct html-block block (kind lines) #:transparent)                      ; leaf
(struct block-quote block (children) #:transparent)                      ; container
(struct list-block block (ordered? start-number delimiter tight? children) #:transparent) ; container
;; task: #f, 'open, 'done, or 'cancelled (extension; unset until mdlib-ext).
(struct list-item block (marker-end content-indent task children) #:transparent) ; container
(struct link-ref-def block (label dest title) #:transparent)             ; leaf, kept in the tree

;; Extensions (mdlib-ext #320). A table's `alignments` is a list of 'left 'center 'right or #f
;; per column; `head` a list of table-cells, `rows` a list of lists of table-cells (every row
;; padded or cut to the header's width; a padding cell is empty, at its row's end). A table-cell
;; is a leaf with inline content, like a paragraph (its `inlines` an inline-cell). Front
;; matter's `fields` is an alist of string keys, or #f when the YAML is beyond the tiny reader.
(struct table block (alignments head rows) #:transparent)
(struct table-cell block (segments inlines) #:transparent)               ; leaf
(struct front-matter block (fields) #:transparent)

;; --- Inlines ------------------------------------------------------------------------------------
;; Spans and tokens as in design §1.2. link/image `kind`: 'inline 'full 'collapsed 'shortcut
;; 'autolink; `label` is the reference label as written (full/collapsed/shortcut) or #f; `dest`
;; and `title` are decoded (escapes, entities; `title` #f when absent), percent-encoding is left
;; to the renderer. wiki-link, tag, date-ref, state-keyword and strike are mdlib-ext's.

(struct inline (start end tokens) #:transparent)
(struct text inline (value) #:transparent)
(struct soft-break inline () #:transparent)
(struct hard-break inline () #:transparent)
(struct emph inline (children) #:transparent)
(struct strong inline (children) #:transparent)
(struct strike inline (children) #:transparent)
(struct code-span inline (value) #:transparent)
(struct link inline (kind dest title children label) #:transparent)
(struct image inline (kind dest title children label) #:transparent)
(struct raw-html inline () #:transparent)
(struct wiki-link inline (target heading alias) #:transparent)
(struct tag inline (name) #:transparent)
(struct date-ref inline (date keyword) #:transparent)
(struct state-keyword inline (keyword) #:transparent)

;; --- The `inlines` slot of a leaf block (design §1.3, §3.1) --------------------------------------
;; A paragraph's or heading's `inlines` field holds an inline-cell, not a list: `content` is the
;; leaf's content string (segments joined by "\n"), `relative` a promise of the inline tree with
;; content-relative offsets (what the HTML renderer reads, and what mdlib-parser's memo will
;; cache), `absolute` a promise of the same tree relocated through `segments` to document
;; offsets (what `block-inlines` returns). Promises keep the inline phase lazy (Source view can
;; skip it, design §3.2); equality forces and compares the content and the absolute tree, so
;; `equal?` on documents stays structural (the incremental test of design §5 relies on it).
(struct inline-cell (content segments relative absolute)
  #:property prop:equal+hash
  (list (lambda (a b recur)
          (and (recur (inline-cell-content a) (inline-cell-content b))
               (recur (force (inline-cell-absolute a)) (force (inline-cell-absolute b)))))
        (lambda (a recur) (recur (force (inline-cell-absolute a))))
        (lambda (a recur) (recur (inline-cell-content a)))))

;; --- Segments -------------------------------------------------------------------------------

;; §1.3: a leaf block's content string is the concatenation (joined by "\n") of its segments'
;; source slices; `content-start`/`content-length` locate a range within that content string,
;; `source-start`/`source-length` locate the corresponding source range (source-length 0 for the
;; virtual spaces of a partially-consumed tab).
(struct segment (content-start content-length source-start source-length) #:transparent)

;; --- Edits ----------------------------------------------------------------------------------

;; One text edit (design §3.1, §4.4): the characters [start, end) of the old text are replaced by
;; `text`. `parser-reparse!` takes one; mdlib-edits' operations will return them.
(struct edit (start end text) #:transparent)

;; --- Extensions -----------------------------------------------------------------------------

(struct extension-set (tables tasks strike autolink-literal wiki tags dates keywords front-matter)
  #:transparent)

(define no-extensions (extension-set #f #f #f #f #f #f #f #f #f))
(define all-extensions (extension-set #t #t #t #t #t #t #t #t #t))
;; GitHub Flavored Markdown's extensions only: tables, task lists, strikethrough, autolinks.
(define gfm-extensions (extension-set #t #t #t #t #f #f #f #f #f))

;; The keyword lists of design §2.3, read when a document is parsed (`parse-document`) or when a
;; parser is made (`make-parser` snapshots them: a list changing under its memo would be unsound).
;; heading-keywords: a heading whose content starts with one of these and a space carries it as
;; `heading-keyword` and a `state-keyword` inline. date-keywords: a date preceded by one of these
;; and a space is a date-ref with that keyword (matched without regard to case).
(define heading-keywords (make-parameter '("TODO" "WAITING" "DONE")))
(define date-keywords (make-parameter '("due")))

;; The heading keyword a heading's content starts with, or #f.
(define (heading-keyword-of content keywords)
  (for/first ([k (in-list keywords)]
              #:when (let ([n (string-length k)])
                       (and (> (string-length content) n)
                            (string=? (substring content 0 n) k)
                            (eqv? (string-ref content n) #\space))))
    k))
