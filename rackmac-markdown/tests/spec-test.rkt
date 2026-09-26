#lang racket/base
;; The spec runner (design §5): iterates the vendored spec-0.31.2.json, parses with
;; no-extensions, renders with #:unsafe? #t (as cmark's own spec tests run `cmark --unsafe`), and
;; compares exactly, printing per-section counts. Every example not listed in
;; known-failures.rktd must match exactly; a listed example that now passes fails the run too,
;; so the file stays an accurate list (design §5: the v0.4 gate is that file being empty).
;; Section thresholds: the block sections of mdlib-blocks (#317) >= 95% on the structural
;; comparator below, the inline sections of mdlib-inlines (#318) >= 95% exact.
(require json racket/list racket/string racket/runtime-path rackunit
         "../main.rkt")

(define-runtime-path spec-path "spec/spec-0.31.2.json")
(define-runtime-path known-failures-path "known-failures.rktd")
(define examples (call-with-input-file spec-path read-json))

;; known-failures.rktd: a list of (example-number "section" "reason").
(define known-failures
  (for/hasheqv ([k (in-list (call-with-input-file known-failures-path read))])
    (values (first k) (third k))))

(define (example-ref e k) (hash-ref e k))

(define (run-example markdown)
  (with-handlers ([exn:fail? (lambda (e) (format "<<<PARSE-ERROR: ~a>>>" (exn-message e)))])
    (document->html (parse-document markdown) #:unsafe? #t)))

;; Sections mdlib-blocks is scored on (design §6.3's acceptance row).
(define block-structure-sections
  '("Tabs" "Thematic breaks" "ATX headings" "Setext headings" "Indented code blocks"
    "Fenced code blocks" "HTML blocks" "Paragraphs" "Blank lines" "Block quotes"
    "List items" "Lists"))

;; Sections mdlib-inlines is scored on (design §6.3; issue #318).
(define inline-sections
  '("Backslash escapes" "Entity and numeric character references" "Code spans"
    "Emphasis and strong emphasis" "Links" "Images" "Autolinks" "Raw HTML"
    "Hard line breaks" "Soft line breaks" "Textual content"))

;; A block-structure comparator, kept from mdlib-blocks so block results stay comparable across
;; phases: both HTML strings reduced to the ordered block-level tag events (p, h1-6, hr, pre,
;; blockquote, ul, ol, li with attributes) plus exact <pre><code> contents.
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

;; (list number exact? markdown expected actual struct?) per example, by section.
(define results-by-section
  (for/fold ([h (hash)]) ([e (in-list examples)])
    (define md (example-ref e 'markdown))
    (define expected (example-ref e 'html))
    (define actual (run-example md))
    (hash-update h (example-ref e 'section)
                 (lambda (rs) (append rs (list (list (example-ref e 'example) (equal? actual expected)
                                                     md expected actual
                                                     (block-structure-match? actual expected)))))
                 '())))
(define (section-results section) (hash-ref results-by-section section))
(define all-results (append-map section-results (hash-keys results-by-section)))

(define all-sections (remove-duplicates (map (lambda (e) (example-ref e 'section)) examples)))

(printf "\n== rackmac-markdown spec conformance (CommonMark 0.31.2, no-extensions) ==\n")
(printf "exact = byte-for-byte cmark match; struct = block-tag skeleton + <pre><code> contents\n\n")
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
                [(member section inline-sections) " [mdlib-inlines]"]
                [else ""])
          exact n (if (> n 0) (round (* 100 (/ exact n))) 0)
          struct-ok n (if (> n 0) (round (* 100 (/ struct-ok n))) 0)))
(printf "\nTOTAL: exact ~a/~a (~a%)  struct ~a/~a (~a%)  known failures listed: ~a\n\n"
        total-exact total-count (round (* 100 (/ total-exact total-count)))
        total-struct total-count (round (* 100 (/ total-struct total-count)))
        (hash-count known-failures))

;; --- CI assertions -------------------------------------------------------------------------

(test-case "every example not in known-failures.rktd matches exactly"
  (for ([r (in-list all-results)] #:unless (or (second r) (hash-ref known-failures (first r) #f)))
    (fail-check (format "example ~a regressed\nmarkdown: ~s\nexpected: ~s\nactual:   ~s"
                        (first r) (third r) (fourth r) (fifth r)))))

(test-case "known-failures.rktd lists only examples that still fail"
  (for ([r (in-list all-results)] #:when (and (second r) (hash-ref known-failures (first r) #f)))
    (fail-check (format "example ~a now passes: remove it from known-failures.rktd" (first r)))))

(for ([section (in-list block-structure-sections)])
  (define results (section-results section))
  (define struct-ok (count sixth results))
  (define n (length results))
  (test-case (format "spec section ~s >= 95% (block structure)" section)
    (check-true (>= (/ struct-ok n) 95/100)
                (format "~a: ~a/~a structurally passed (~a)" section struct-ok n
                        (for/list ([r (in-list results)] #:unless (sixth r)) (first r))))))

(for ([section (in-list inline-sections)])
  (define results (section-results section))
  (define exact (count second results))
  (define n (length results))
  (test-case (format "spec section ~s >= 95% (exact)" section)
    (check-true (>= (/ exact n) 95/100)
                (format "~a: ~a/~a exact (~a)" section exact n
                        (for/list ([r (in-list results)] #:unless (second r)) (first r))))))
