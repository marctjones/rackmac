#lang racket/base
;; Heading keyword states (#294 task-heading-states, docs/REPLAN.md E17.M1). A heading line whose
;; text starts with a configured keyword and a space is already parsed by rackmac-markdown as a
;; `state-keyword` inline (design §2.3; the `md-parser` dependency this issue names). This module
;; is the app-level sibling of the task checkbox (#293, md-checkbox.rkt): it colors that word by
;; its state and cycles it with Mark Done (⇧⌘U, md-format.rkt), the same shortcut UI-DESIGN's
;; shortcut table gives both. Unlike a checkbox, the word is never a snip -- it stays plain styled
;; text, so save, export and copy see it unchanged (doc-text.rkt walks text and source snips only,
;; and a colored run is neither).
;;
;; The keyword list is one setting, `heading-state-keywords` (a space-separated string, so the
;; generated Settings dialog edits it as an ordinary text field rather than a Racket list
;; literal). This app has only one Library (an ordered list of folders, rackmac/library/folders.rkt)
;; and no per-folder settings store, so "keyword list per Library" (the issue's acceptance
;; criterion) reads here as "the whole Library shares one list" -- the same shape as
;; `library-folders` and `templates-folder`, Library-wide rather than per-document or per-Language
;; (settings.rkt only has those two scopes). A future multi-Library settings store could re-home
;; this setting without changing anything below `heading-state-keyword-list`.
;;
;; Changing the setting reparameterizes rackmac-markdown's `heading-keywords` (snapshotted per
;; parser at `make-parser`, design §3.1, and read fresh by `parse-document`), so new words are
;; recognized from the next parse; md-format.rkt rehighlights every open document on the same
;; 'setting-changed hook (this module stays below editor.rkt/modes.rkt in the require graph --
;; md-style.rkt, which every Language module reaches through modes.rkt, requires this module for
;; the coloring below, so this module must never itself reach back up to editor.rkt).
(require racket/list racket/string
         "settings.rkt" "hook.rkt" "markdown-lib.rkt")
(provide heading-state-keyword-list heading-keyword-style-role heading-line-at?
         cycle-heading-keyword-edits sync-heading-keywords!)

(define-setting heading-state-keywords
  #:contract string? #:default "TODO WAITING DONE"
  #:category "Library"
  #:doc "Words that color and cycle at the start of a heading line (space-separated; first = open, last = done).")

;; The configured words, in order: the first is the "not started" state (colored `error`), the
;; last is "done" (`success`); anything between is "in progress" (`warning`). UI-DESIGN §2.3 says
;; only "keyword bold in the state's color", not which color goes with which word -- this
;; position-based reading of the default TODO/WAITING/DONE list, generalized to a shorter or
;; longer one, is this module's judgment call.
(define (heading-state-keyword-list) (string-split (setting-ref 'heading-state-keywords)))

;; Applies the setting to the shared rackmac-markdown parameter; no parse call site needs to know
;; about the setting itself. Exported so md-format.rkt's own 'setting-changed hook (which
;; rehighlights every open document) can call it explicitly, first, before rehighlighting:
;; `run-hook` (hook.rkt) runs same-priority hooks most-recently-added first, so relying on this
;; hook alone racing that one would rehighlight with the *old* parameter value on some load
;; orders. Calling it here too keeps this module correct standalone (e.g. in a context that
;; parses documents without md-format.rkt loaded at all).
(define (sync-heading-keywords!) (heading-keywords (heading-state-keyword-list)))

(sync-heading-keywords!)
(add-hook! 'setting-changed
           (lambda (name . _) (when (eq? name 'heading-state-keywords) (sync-heading-keywords!))))

;; ---- coloring -----------------------------------------------------------------------------

;; `node` is a style run's node (rackmac-markdown/runs.rkt: "a `keyword` run's node is the
;; state-keyword whose value it shows"); md-style.rkt substitutes this role for the plain
;; `keyword` one it gets from style-runs, so `apply-role` there can color it. This always reads
;; the live setting (`heading-state-keyword-list`, not the rackmac-markdown parameter), so it is
;; never stale itself; the `(not i)` fallback below only guards a `node` that was recognized under
;; a keyword list rackmac-markdown has since moved past (the same race `cycle-heading-keyword-edits`
;; guards, and just as unreachable once `sync-heading-keywords!` runs before every rehighlight) --
;; bold with no color, rather than a role this run cannot justify.
(define (heading-keyword-style-role node)
  (define kw (and (state-keyword? node) (state-keyword-keyword node)))
  (define ks (heading-state-keyword-list))
  (define i (and kw (index-of ks kw)))
  (cond
    [(not i) 'keyword]
    [(= i 0) 'keyword-open]
    [(= i (sub1 (length ks))) 'keyword-done]
    [else 'keyword-waiting]))

;; ---- cycling --------------------------------------------------------------------------------

(define (heading-line-at? doc pos) (and (heading? (block-at doc pos)) #t))

;; The heading's first inline node (the `state-keyword` when it has one, else its first text), or
;; #f for an empty heading. Absolute positions: `block-inlines` relocates content-relative ones
;; through the leaf's segments, so this is right even with extra spaces after the `#`s.
(define (heading-first-inline h)
  (define inls (block-inlines h))
  (and (pair? inls) (car inls)))

;; Cycles the heading at `pos`, as one set of edits (md-format.rkt applies them, like
;; toggle-task-at! does for the checkbox): no keyword -> the first configured word; word at index
;; i (i < last) -> the next word; the last word -> no keyword (the word and the one space after it
;; removed). `current` (the word rackmac-markdown actually parsed) is always one `ks` has, because
;; a parse only ever produces a `state-keyword` for a word in the list current at parse time, and
;; `sync-heading-keywords!` keeps every open document reparsed against the live setting before
;; this runs; the fallback below (treat an unrecognized `current` as the last word, so cycling
;; simply drops it) only guards a caller that hands this a document parsed under a different
;; keyword list than the one configured now. No heading at `pos`, or an empty keyword list: no
;; edits.
(define (cycle-heading-keyword-edits doc pos)
  (define h (block-at doc pos))
  (define ks (heading-state-keyword-list))
  (cond
    [(or (not (heading? h)) (null? ks)) '()]
    [else
     (define text (document-text doc))
     (define first (heading-first-inline h))
     (define current (and first (state-keyword? first) (state-keyword-keyword first)))
     (define i (and current (index-of ks current)))
     (cond
       [(not current)
        (define p (if first (inline-start first) (block-end h)))
        ;; An empty heading ("#" alone) has no required space after its marker to land before
        ;; (try-atx only consumes one when there is content to separate it from); a heading with
        ;; content already has it, from the "# " the parser required.
        (define ins (if first (string-append (car ks) " ") (string-append " " (car ks))))
        (list (edit p p ins))]
       [(and i (< i (sub1 (length ks))))
        (list (edit (inline-start first) (inline-end first) (list-ref ks (add1 i))))]
       [else
        (define after
          (if (and (< (inline-end first) (string-length text))
                   (eqv? (string-ref text (inline-end first)) #\space))
              (add1 (inline-end first))
              (inline-end first)))
        (list (edit (inline-start first) after ""))])]))
