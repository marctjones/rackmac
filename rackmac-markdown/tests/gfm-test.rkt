#lang racket/base
;; The GFM extension examples (design §5, mdlib-ext #320): the 24 examples of the GitHub Flavored
;; Markdown spec 0.29's extension sections (spec/gfm-0.29-extensions.json, see spec/LICENSE.md)
;; minus the tagfilter one (design §4.2: not implemented), parsed with GFM's extensions
;; (`gfm-extensions`) and rendered exactly as the spec shows. The same 23 must also pass with
;; `all-extensions` (our wiki links, tags, dates, keywords and front matter do not disturb GFM
;; output), and with `no-extensions` none of the extension constructs appear.
(require json racket/list racket/runtime-path rackunit "../main.rkt")

(define-runtime-path gfm-path "spec/gfm-0.29-extensions.json")
(define examples
  (filter (lambda (e) (not (equal? (hash-ref e 'extension) "tagfilter")))
          (call-with-input-file gfm-path read-json)))

(define (render md exts)
  (with-handlers ([exn:fail? (lambda (e) (format "<<<ERROR: ~a>>>" (exn-message e)))])
    (document->html (parse-document md #:extensions exts) #:unsafe? #t)))

(define (score exts)
  (for/list ([e (in-list examples)])
    (list (hash-ref e 'example) (equal? (render (hash-ref e 'markdown) exts) (hash-ref e 'html)) e)))

(define gfm-results (score gfm-extensions))
(define all-results (score all-extensions))
(printf "\n== GFM 0.29 extension examples (tagfilter skipped) ==\n")
(for ([ext (in-list (remove-duplicates (map (lambda (e) (hash-ref e 'extension)) examples)))])
  (define rs (filter (lambda (r) (equal? (hash-ref (third r) 'extension) ext)) gfm-results))
  (printf "~a: ~a/~a\n" ext (count second rs) (length rs)))
(printf "TOTAL: ~a/~a with gfm-extensions, ~a/~a with all-extensions\n\n"
        (count second gfm-results) (length gfm-results) (count second all-results) (length all-results))

(test-case "the 23 GFM extension examples match exactly"
  (check-equal? (length examples) 23)
  (for ([rs (in-list (list gfm-results all-results))] [name '("gfm-extensions" "all-extensions")])
    (for ([r (in-list rs)] #:unless (second r))
      (define e (third r))
      (fail-check (format "~a: example ~a (~a)\nmarkdown: ~s\nexpected: ~s\nactual:   ~s" name (first r)
                          (hash-ref e 'extension) (hash-ref e 'markdown) (hash-ref e 'html)
                          (render (hash-ref e 'markdown) (if (equal? name "gfm-extensions") gfm-extensions all-extensions)))))))

(test-case "with no-extensions the extension constructs are plain CommonMark"
  (for ([e (in-list examples)])
    (define html (render (hash-ref e 'markdown) no-extensions))
    (check-false (regexp-match? #rx"<table>|<del>|<input|href=\"(http://www|mailto:)" html)
                 (format "example ~a: ~s" (hash-ref e 'example) html))))
