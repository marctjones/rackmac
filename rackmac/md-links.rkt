#lang racket/base
;; Links in a Markdown note (#338, docs/UI-DESIGN.md §2.2): which link is under a position, and
;; where it points. Pure apart from reading the document; md-links-open.rkt does the opening, and
;; buffer% calls `markdown-link-at` (the markdown-mode local `link-at`) for ⌘-click and hover.
;;
;; Formatted view: the parser's current document, so reference links resolve. Source view keeps
;; no parse, so the one line under the pointer is parsed on its own (inline links, autolinks and
;; wiki links work; reference links need their definitions and do not).
(require racket/class racket/string racket/list racket/path net/uri-codec net/url
         "../rackmac-markdown/main.rkt" "md-style.rkt")
(provide markdown-link-at link-target-at resolve-link)

;; The target of the link covering `pos` in `doc`, as written: a URL or path for a link or
;; autolink, "[[Target]]" for a wiki link; #f when there is none.
(define (link-target-at doc pos)
  (define blk (block-at doc pos))
  (and blk (leaf-block? blk)
       (let find ([inls (block-inlines blk)])
         (for/or ([i (in-list inls)] #:when (and (<= (inline-start i) pos) (< pos (inline-end i))))
           (cond
             [(link? i) (link-dest i)]
             [(wiki-link? i) (string-append "[[" (wiki-link-target i) "]]")]
             [(emph? i) (find (emph-children i))]
             [(strong? i) (find (strong-children i))]
             [(strike? i) (find (strike-children i))]
             [else #f])))))

;; The markdown-mode local `link-at`: (document position) -> target or #f.
(define (markdown-link-at b pos)
  (define doc (and (not (eq? (send b local-ref 'markdown-view 'formatted) 'source))
                   (markdown-parser-document b)))
  (cond
    [(and doc (= (string-length (document-text doc)) (send b last-position)))
     (link-target-at doc pos)]
    [else                                          ; Source view: the line alone
     (define para (send b position-paragraph pos))
     (define start (send b paragraph-start-position para))
     (define line (send b get-text start (send b paragraph-end-position para)))
     (link-target-at (parse-document line #:extensions all-extensions) (- pos start))]))

;; Where a target points, for a note at `note-path` (#f when untitled):
;;   (values 'url string)        http, https, mailto: the browser or mail app
;;   (values 'note path)         a Markdown file: opens in Rackmac
;;   (values 'file path)         any other file or folder: the default app
;;   (values 'missing string)    a relative path in an untitled note, or a file that isn't there
;;   (values 'unsupported str)   another URL scheme, or a link to a place in the same note
;; Relative paths resolve against the note's folder; percent-escapes are decoded; a #fragment
;; is dropped. A wiki link "[[Target]]" names Target.md in the note's folder (the Library's
;; title lookup replaces this with v0.4 wiki links).
(define (resolve-link target note-path)
  (define dir (and note-path (let-values ([(base name dir?) (split-path note-path)])
                               (and (path? base) base))))
  (define (local rel)
    (define decoded (uri-decode (car (string-split (string-append rel " ") "#"))))
    (define clean (string-trim decoded))
    (cond
      [(string=? clean "") (values 'unsupported target)]
      [(absolute-path? clean) (classify (simplify-path clean))]
      [dir (classify (simplify-path (build-path dir clean)))]
      [else (values 'missing target)]))
  (define (classify p)
    (cond
      [(not (or (file-exists? p) (directory-exists? p))) (values 'missing (path->string p))]
      [(and (file-exists? p) (member (path-get-extension p) '(#".md" #".markdown" #".MD"))) (values 'note p)]
      [else (values 'file p)]))
  (cond
    [(regexp-match #px"^\\[\\[(.*)\\]\\]$" target)
     => (lambda (m)
          (define name (string-trim (car (string-split (string-append (cadr m) "|") "|"))))
          (local (if (regexp-match? #rx"(?i:[.](md|markdown))$" name) name (string-append name ".md"))))]
    [(regexp-match? #px"^(?i:https?|mailto):" target) (values 'url target)]
    [(regexp-match? #px"^(?i:file):" target)
     (with-handlers ([exn:fail? (lambda (e) (values 'unsupported target))])
       (classify (simplify-path (url->path (string->url target)))))]
    [(regexp-match? #px"^[A-Za-z][A-Za-z0-9+.-]+:" target) (values 'unsupported target)]
    [(regexp-match? #px"^#" target) (values 'unsupported target)]
    [else (local target)]))
