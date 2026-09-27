#lang racket/base
;; What the Library index (#302 lib-index, rackmac/library/index.rkt) stores about one note,
;; extracted from its text in one pass: title, headings, tags, links, tasks and dates. Pure (no
;; GUI, no database, no file access), so it is tested on strings and the index's worker thread
;; can call it freely.
;;
;; It walks the AST rackmac-markdown already builds (the extension nodes `tag`, `wiki-link`,
;; `date-ref`, `state-keyword`, a list item's `task`, front matter's fields), the way
;; rackmac/headings.rkt walks it for headings -- whose `document-headings` and `inlines->text`
;; it reuses. rackmac-markdown's design (§6.2) plans `document-links/tags/tasks/dates` for this;
;; they are not built yet, and the library is another lane, so the walk lives here.
;;
;; Positions: `pos` is a 0-based offset into the note's text as rackmac/fileio.rkt's
;; decode-file returns it (line endings normalized to "\n"), i.e. the text% position of the open
;; note; `line` is 1-based. `context` is that whole source line, for a result list.
(require racket/list racket/string racket/path
         "../markdown-lib.rkt" "../headings.rkt")
(provide (struct-out note-facts)
         (struct-out heading-fact) (struct-out tag-fact) (struct-out link-fact)
         (struct-out task-fact) (struct-out date-fact)
         markdown-path? extract-note-facts plain-note-facts)

;; title: the front matter's `title:`, else the first heading's text, else `fallback-title`.
(struct note-facts (title headings tags links tasks dates) #:transparent)
(struct heading-fact (level text pos line) #:transparent)
;; name: without the "#", as written. pos/line #f for a front-matter tag.
(struct tag-fact (name pos line) #:transparent)
;; kind: 'wiki ([[target#heading|alias]]), 'file (a Markdown link to a relative path), or 'url
;; (anything with a scheme, `mailto:`, `#fragment`-only links). target: the wiki target or the
;; link destination as written (decoded). heading: the wiki `#heading` or the link's fragment.
;; resolved: for 'file, the complete path the destination names (relative to the note's folder,
;; fragment dropped, percent-decoded); #f otherwise -- wiki targets resolve at query time, since
;; titles change as other notes change.
(struct link-fact (kind target heading resolved pos line context) #:transparent)
;; kind: 'checkbox (`- [ ]`, `- [x]`, `- [-]`) or 'heading (a heading keyword, #294).
;; state: 'open, 'done or 'cancelled. keyword: the heading keyword, or #f for a checkbox.
;; due: "YYYY-MM-DD" from `due 2026-09-30` in the task's own text, or #f.
(struct task-fact (kind state keyword text due pos line) #:transparent)
;; date: "YYYY-MM-DD"; keyword: e.g. "due", or #f.
(struct date-fact (date keyword pos line context) #:transparent)

(define (markdown-path? p)
  (and (member (path-get-extension p) '(#".md" #".markdown")) #t))

;; A note that is not Markdown (.txt, .rkt, .py) is indexed by name and full text only.
(define (plain-note-facts fallback-title) (note-facts fallback-title '() '() '() '() '()))

;; text: the note's text. note-path: its complete path (for resolving relative links).
;; heading-keywords: the configured heading states (md-heading-state.rkt's list; first = not
;; started, last = done).
(define (extract-note-facts text note-path fallback-title
                            #:heading-keywords [keywords (heading-keywords)])
  (define doc (parameterize ([heading-keywords keywords])
                (parse-document text #:extensions all-extensions)))
  (define dir (let-values ([(base name dir?) (split-path note-path)]) (if (path? base) base (current-directory))))
  (define (line-of pos) (let-values ([(l c) (offset->line+col doc (min pos (string-length text)))]) (add1 l)))
  (define (context-of pos)
    (define p (min pos (string-length text)))
    (define s (let loop ([i p]) (if (and (> i 0) (not (char=? (string-ref text (sub1 i)) #\newline))) (loop (sub1 i)) i)))
    (define e (let loop ([i p]) (if (and (< i (string-length text)) (not (char=? (string-ref text i) #\newline))) (loop (add1 i)) i)))
    (string-trim (substring text s e)))
  (define done-keyword (and (> (length keywords) 1) (last keywords)))

  (define tags '()) (define links '()) (define dates '()) (define tasks '())
  (define (add-tag! t) (set! tags (cons t tags)))

  ;; Inline walk: every tag, link and date under these inlines, however nested.
  (define (walk-inlines xs)
    (for ([x (in-list xs)])
      (define pos (inline-start x))
      (cond
        [(tag? x) (add-tag! (tag-fact (tag-name x) pos (line-of pos)))]
        [(wiki-link? x)
         (set! links (cons (link-fact 'wiki (string-trim (wiki-link-target x)) (wiki-link-heading x) #f
                                      pos (line-of pos) (context-of pos))
                           links))]
        [(link? x)
         (set! links (cons (markdown-link-fact (link-dest x) dir pos (line-of pos) (context-of pos)) links))
         (walk-inlines (link-children x))]
        [(date-ref? x)
         (set! dates (cons (date-fact (date-ref-date x) (date-ref-keyword x) pos (line-of pos) (context-of pos)) dates))]
        [(emph? x) (walk-inlines (emph-children x))]
        [(strong? x) (walk-inlines (strong-children x))]
        [(strike? x) (walk-inlines (strike-children x))]
        [(image? x) (walk-inlines (image-children x))]   ; an image is not a link, but its alt text may tag
        [else (void)])))

  ;; The due date among a task's own inlines (not its nested items').
  (define (due-in xs)
    (for/or ([x (in-list (flatten-inlines xs))])
      (and (date-ref? x) (date-ref-keyword x) (string-ci=? (date-ref-keyword x) "due") (date-ref-date x))))

  (define (walk-blocks bs)
    (for ([b (in-list bs)])
      (cond
        [(heading? b)
         (define xs (block-inlines b))
         (walk-inlines xs)
         (define kw (heading-keyword b))
         (when kw
           (set! tasks (cons (task-fact 'heading (if (equal? kw done-keyword) 'done 'open) kw
                                        (string-normalize-spaces (inlines->text xs)) (due-in xs)
                                        (block-start b) (line-of (block-start b)))
                             tasks)))]
        [(paragraph? b) (walk-inlines (block-inlines b))]
        [(table? b) (for ([c (in-list (append (table-head b) (append* (table-rows b))))])
                      (walk-inlines (block-inlines c)))]
        [(block-quote? b) (walk-blocks (block-quote-children b))]
        [(list-block? b) (walk-blocks (list-block-children b))]
        [(list-item? b)
         (define st (list-item-task b))
         (when st
           (define first-para (let ([cs (list-item-children b)]) (and (pair? cs) (paragraph? (car cs)) (car cs))))
           (define xs (if first-para (block-inlines first-para) '()))
           (set! tasks (cons (task-fact 'checkbox st #f (string-normalize-spaces (inlines->text xs)) (due-in xs)
                                        (block-start b) (line-of (block-start b)))
                             tasks)))
         (walk-blocks (list-item-children b))]
        [else (void)])))

  (define blocks (document-blocks doc))
  (walk-blocks blocks)

  (define fields (for/or ([b (in-list blocks)]) (and (front-matter? b) (or (front-matter-fields b) '()))))
  (define (field k) (and fields (for/or ([kv (in-list fields)]) (and (string-ci=? (car kv) k) (cdr kv)))))
  (define fm-tags
    (let ([v (field "tags")])
      (for/list ([t (in-list (cond [(string? v) (string-split v #px"[,\\s]+")] [(list? v) v] [else '()]))]
                 #:unless (string=? (string-trim t) ""))
        (tag-fact (regexp-replace #rx"^#" (string-trim t) "") #f #f))))
  (define headings
    (for/list ([h (in-list (document-headings doc))])
      (heading-fact (doc-heading-level h) (doc-heading-text h) (doc-heading-start h) (line-of (doc-heading-start h)))))
  (define title
    (or (let ([t (field "title")]) (and (string? t) (not (string=? (string-trim t) "")) (string-trim t)))
        (for/or ([h (in-list headings)]) (and (not (string=? (heading-fact-text h) "")) (heading-fact-text h)))
        fallback-title))
  (note-facts title headings
              (append fm-tags (reverse tags))
              (sort (reverse links) < #:key link-fact-pos)
              (sort (reverse tasks) < #:key task-fact-pos)
              (sort (reverse dates) < #:key date-fact-pos)))

(define (flatten-inlines xs)
  (append* (for/list ([x (in-list xs)])
             (cons x (cond [(emph? x) (flatten-inlines (emph-children x))]
                           [(strong? x) (flatten-inlines (strong-children x))]
                           [(strike? x) (flatten-inlines (strike-children x))]
                           [(link? x) (flatten-inlines (link-children x))]
                           [else '()])))))

;; A Markdown link: a URL (has a scheme, or is only a #fragment) or a file relative to the note.
(define (markdown-link-fact dest dir pos line context)
  (define d (string-trim dest))
  (cond
    [(or (regexp-match? #px"^[A-Za-z][A-Za-z0-9+.-]*:" d) (regexp-match? #rx"^#" d) (string=? d ""))
     (link-fact 'url d #f #f pos line context)]
    [else
     (define m (regexp-match #rx"^([^#]*)(?:#(.*))?$" d))
     (define file-part (percent-decode (cadr m)))
     (define frag (caddr m))
     (define resolved
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (path->string (simplify-path (path->complete-path (string->path file-part) dir) #f))))
     (link-fact 'file d frag resolved pos line context)]))

(define (percent-decode s)
  (with-handlers ([exn:fail? (lambda (e) s)])
    (define bs
      (let loop ([i 0] [acc '()])
        (cond
          [(>= i (string-length s)) (apply bytes-append (reverse acc))]
          [(and (char=? (string-ref s i) #\%) (<= (+ i 3) (string-length s))
                (string->number (substring s (add1 i) (+ i 3)) 16))
           => (lambda (n) (loop (+ i 3) (cons (bytes n) acc)))]
          [else (loop (add1 i) (cons (string->bytes/utf-8 (string (string-ref s i))) acc))])))
    (bytes->string/utf-8 bs)))
