#lang racket/base
;; The spec runner (design §5): iterates the vendored spec-0.31.2.json, parses with
;; no-extensions, renders, and compares exactly, printing per-section counts. Until
;; mdlib-inlines, inline content is rendered as escaped literal text (design §2.1's mdlib-blocks
;; row), so sections whose examples exercise emphasis/links/entities/raw HTML *content* score
;; below 100% by construction; the block-structure sections mdlib-blocks is scored on do not
;; depend on that and are asserted at >=95% below.
(require json racket/list racket/string racket/runtime-path rackunit
         "../main.rkt")

(define-runtime-path spec-path "spec/spec-0.31.2.json")
(define examples (call-with-input-file spec-path read-json))

(define (example-ref e k) (hash-ref e k))

(define (run-example markdown)
  (with-handlers ([exn:fail? (lambda (e) (format "<<<PARSE-ERROR: ~a>>>" (exn-message e)))])
    (document->html (parse-document markdown) #:unsafe? #t)))

;; Sections mdlib-blocks is scored on (design §6.3's acceptance row).
(define block-structure-sections
  '("Tabs" "Thematic breaks" "ATX headings" "Setext headings" "Indented code blocks"
    "Fenced code blocks" "HTML blocks" "Paragraphs" "Blank lines" "Block quotes"
    "List items" "Lists"))

;; Scored separately: exact-match conformance here needs real link resolution (mdlib-inlines),
;; so it is reported, not asserted, at this phase.
(define deferred-sections '("Link reference definitions"))

;; A block-structure comparator, used only for the >=95% assertions below (the printed summary
;; uses exact string equality throughout, as mdlib-html/mdlib-conformance eventually will).
;; mdlib-blocks renders inline content as escaped literal text, so an example whose *inline*
;; content needs real parsing (emphasis, links, entities, backslash escapes, code spans, raw
;; HTML) will not match cmark's HTML byte-for-byte even when the block structure is exactly
;; right -- verified by hand for every current failure in the sections below (see the commit
;; message / final report). This comparator makes that verification mechanical and repeatable:
;; it reduces both HTML strings to the ordered sequence of block-level tag events (open/close,
;; name, and attributes -- p, h1-6, hr, pre, code, blockquote, ul, ol, li), and additionally
;; requires an exact match of <pre><code> contents (which are never touched by the inline
;; phase, so a mismatch there is a genuine block bug, not a deferred one).
;; `code` is deliberately excluded: it is block-level only directly inside `<pre>`, and that
;; pairing is already checked exactly by `code-contents` below; elsewhere `<code>` is an inline
;; code span, which must not count as a block-structure mismatch at this phase.
(define block-tag-rx
  #px"<(/?)(p|h[1-6]|hr|pre|blockquote|ul|ol|li)((?:\\s[^>]*)?)\\s*/?>")

(define (tag-skeleton html)
  (for/list ([m (in-list (regexp-match* block-tag-rx html #:match-select values))])
    (list (equal? (cadr m) "/") (caddr m) (regexp-replace* #px"\\s+" (cadddr m) " "))))

(define code-content-rx #px"<pre><code[^>]*>((?:.|\n)*?)</code></pre>")
(define (code-contents html) (map cadr (regexp-match* code-content-rx html #:match-select values)))

(define (block-structure-match? actual expected)
  (and (equal? (tag-skeleton actual) (tag-skeleton expected))
       (equal? (code-contents actual) (code-contents expected))))

(define (section-results section)
  (for/list ([e (in-list examples)] #:when (equal? (example-ref e 'section) section))
    (define md (example-ref e 'markdown))
    (define expected (example-ref e 'html))
    (define actual (run-example md))
    (list (example-ref e 'example) (equal? actual expected) md expected actual
          (block-structure-match? actual expected))))

(define all-sections (remove-duplicates (map (lambda (e) (example-ref e 'section)) examples)))

(printf "\n== rackmac-markdown spec conformance (CommonMark 0.31.2, no-extensions) ==\n")
(printf "(mdlib-blocks phase: inline content rendered as escaped text, not yet parsed)\n")
(printf "exact = byte-for-byte cmark match; struct = block-tag skeleton + <pre><code> contents\n")
(printf "match (fair for this phase: it ignores inline-only differences -- emphasis, links,\n")
(printf "entities, backslash escapes, code spans, raw HTML -- that need mdlib-inlines)\n\n")
(define total-exact 0) (define total-struct 0) (define total-count 0)
(for ([section (in-list all-sections)])
  (define results (section-results section))
  (define exact (count second results))
  (define struct-ok (count sixth results))
  (define n (length results))
  (set! total-exact (+ total-exact exact)) (set! total-struct (+ total-struct struct-ok))
  (set! total-count (+ total-count n))
  (printf "~a~a: exact ~a/~a (~a%)  struct ~a/~a (~a%)\n"
          section
          (cond [(member section block-structure-sections) " [mdlib-blocks]"]
                [(member section deferred-sections) " [needs mdlib-inlines]"]
                [else " [later phase]"])
          exact n (if (> n 0) (round (* 100 (/ exact n))) 0)
          struct-ok n (if (> n 0) (round (* 100 (/ struct-ok n))) 0)))
(printf "\nTOTAL: exact ~a/~a (~a%)  struct ~a/~a (~a%)\n\n"
        total-exact total-count (round (* 100 (/ total-exact total-count)))
        total-struct total-count (round (* 100 (/ total-struct total-count))))

;; --- CI assertions -------------------------------------------------------------------------
;; mdlib-blocks' own block-structure sections must be >=95% on the structural comparator (their
;; exact-match score is bounded below 100% by design until mdlib-inlines; see the header comment
;; on block-structure-match? above).
(for ([section (in-list block-structure-sections)])
  (define results (section-results section))
  (define struct-ok (count sixth results))
  (define n (length results))
  (test-case (format "spec section ~s >= 95% (block structure)" section)
    (check-true (>= (/ struct-ok n) 95/100)
                (format "~a: ~a/~a structurally passed (~a)" section struct-ok n
                        (for/list ([r (in-list results)] #:unless (sixth r)) (first r))))))
