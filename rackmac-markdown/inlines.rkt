#lang racket/base
;; Phase 2 (design §2.2): inline parsing of one leaf block's content string, following the
;; spec's appendix ("Phase 2: inline structure") as commonmark.js and cmark implement it: a
;; subject scanned left to right, a delimiter stack for `*`/`_` runs, a bracket stack for `[`
;; and `![`, link matching at `]`, and `process-emphasis` with the rule of 3 and the
;; openers-bottom table. Every node records its span and markup tokens as it is made, in
;; content-relative offsets; `relocate-inlines` maps them to document offsets through the leaf's
;; segments (design §1.3).
;;
;; Linear-time guards for cmark's pathological inputs (design §5): backtick closers found through
;; a one-time index of runs by length; raw-HTML closers (`-->`, `?>`, `]]>`, `>`) memoized once
;; known absent; link-destination parenthesis nesting capped at 32; reference labels checked
;; against the bracket-after flag and the 999-character limit before any slicing; "no links in
;; links" by a counter instead of a walk down the bracket stack.
(require racket/list racket/promise racket/string
         "ast.rkt" "chars.rkt" "entities.rkt" "refs.rkt")
(provide parse-inlines relocate-inlines
         (struct-out inline-options) default-inline-options
         make-inline-cell cell-inlines cell-relative-inlines empty-inline-cell)

;; What an inline parse depends on besides the content and the refmap (design §2.3, §3.1): the
;; extension set, the leaf's kind ('paragraph 'heading 'table-cell: only headings get state
;; keywords), and the keyword lists (snapshotted by the parser object, so they key its memo).
(struct inline-options (extensions kind heading-keywords date-keywords) #:transparent)
(define default-inline-options (inline-options no-extensions 'paragraph '() '()))

;; ============================================================================================
;; Mutable working tree (a doubly linked child list, as commonmark.js uses) and the stacks.
;; ============================================================================================

;; kind: 'root 'text 'soft-break 'hard-break 'code 'emph 'strong 'link 'image 'html
;; value: decoded text (text, code); data: (vector kind dest title label) for link/image.
(struct nd (kind [start #:mutable] [end #:mutable] [tokens #:mutable] [value #:mutable] data
                 [parent #:mutable] [prev #:mutable] [next #:mutable]
                 [first #:mutable] [last #:mutable]))

(define (mk kind start end [value #f] [tokens '()] [data #f])
  (nd kind start end tokens value data #f #f #f #f #f))

(define (append-child! p c)
  (define last (nd-last p))
  (set-nd-parent! c p) (set-nd-next! c #f) (set-nd-prev! c last)
  (if last (set-nd-next! last c) (set-nd-first! p c))
  (set-nd-last! p c))

(define (unlink! c)
  (define p (nd-parent c))
  (if (nd-prev c) (set-nd-next! (nd-prev c) (nd-next c)) (when p (set-nd-first! p (nd-next c))))
  (if (nd-next c) (set-nd-prev! (nd-next c) (nd-prev c)) (when p (set-nd-last! p (nd-prev c))))
  (set-nd-parent! c #f) (set-nd-prev! c #f) (set-nd-next! c #f))

(define (insert-after! ref c)
  (define p (nd-parent ref))
  (define nx (nd-next ref))
  (set-nd-parent! c p) (set-nd-prev! c ref) (set-nd-next! c nx) (set-nd-next! ref c)
  (if nx (set-nd-prev! nx c) (set-nd-last! p c)))

;; A `*` or `_` delimiter run (spec, "Emphasis and strong emphasis"); `node` is its text node.
(struct dl (char [count #:mutable] orig node can-open? can-close? [prev #:mutable] [next #:mutable]))

;; A `[` or `![` opener: `pos` is the index of its `[`; `bottom` the delimiter-stack top when it
;; was pushed; `after?` set once another bracket is pushed above it (so its text cannot be a
;; reference label); `links` the number of links formed before it was pushed (a link opener is
;; inactive once a link has formed after it: "links may not contain links").
(struct br (node pos image? bottom [after? #:mutable] prev links))

;; ============================================================================================
;; The parser.
;; ============================================================================================


(define rx-autolink-uri #px"^<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\u0000-\u0020]*>")
(define rx-autolink-email
  #px"^<[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:[.][a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>")
(define html-attribute
  "(?:\\s+[a-zA-Z_:][a-zA-Z0-9:._-]*(?:\\s*=\\s*(?:[^\"'=<>`\u0000-\u0020]+|'[^']*'|\"[^\"]*\"))?)")
(define rx-open-tag (pregexp (string-append "^<[A-Za-z][A-Za-z0-9-]*" html-attribute "*\\s*/?>")))
(define rx-close-tag #px"^</[A-Za-z][A-Za-z0-9-]*\\s*>")

;; Parses `s` (a leaf block's content) against `refmap` (normalized label -> (list dest title
;; node)); returns the list of inline nodes (ast.rkt structs) with content-relative offsets.
(define (parse-inlines s refmap [opts default-inline-options])
  (define n (string-length s))
  (define ext (inline-options-extensions opts))
  (define strike? (extension-set-strike ext))
  (define wiki? (extension-set-wiki ext))
  (define (special? c)
    (case c [(#\newline #\\ #\` #\* #\_ #\[ #\] #\! #\< #\&) #t] [(#\~) strike?] [else #f]))
  (define root (mk 'root 0 n))
  (define delims #f)        ; top of the delimiter stack
  (define brackets #f)      ; top of the bracket stack
  (define links-formed 0)
  (define backtick-runs #f) ; length -> vector of run starts, built on first use
  (define html-absent (make-hasheq)) ; closer kind -> smallest start known to have no closer

  (define (add! node) (append-child! root node) node)
  (define (add-text! start end [value (substring s start end)] [tokens '()])
    (add! (mk 'text start end value tokens)))

  (define (skip-line-indent pos)
    (if (and (< pos n) (space-or-tab? (string-ref s pos))) (skip-line-indent (add1 pos)) pos))

  ;; --- plain text ---------------------------------------------------------------------------
  (define (scan-text pos)
    (define stop (let loop ([i pos]) (if (and (< i n) (not (special? (string-ref s i)))) (loop (add1 i)) i)))
    ;; Before a line ending, trailing spaces and tabs are not text (spec, "Hard line breaks",
    ;; "Soft line breaks"); they stay outside every node.
    (define end
      (if (and (< stop n) (eqv? (string-ref s stop) #\newline))
          (let back ([j stop]) (if (and (> j pos) (space-or-tab? (string-ref s (sub1 j)))) (back (sub1 j)) j))
          stop))
    (when (> end pos) (add-text! pos end))
    stop)

  ;; --- line endings ---------------------------------------------------------------------------
  (define (handle-newline pos)
    (define floor (let ([l (nd-last root)]) (if l (nd-end l) 0)))
    (define ws-start
      (let back ([j pos]) (if (and (> j floor) (space-or-tab? (string-ref s (sub1 j)))) (back (sub1 j)) j)))
    (if (and (>= pos 2) (eqv? (string-ref s (- pos 1)) #\space) (eqv? (string-ref s (- pos 2)) #\space))
        (add! (mk 'hard-break ws-start (add1 pos) #f (list (token 'hard-break-marker ws-start pos))))
        (add! (mk 'soft-break pos (add1 pos))))
    (skip-line-indent (add1 pos)))

  ;; --- backslash ----------------------------------------------------------------------------
  (define (handle-backslash pos)
    (define nx (add1 pos))
    (cond
      [(and (< nx n) (eqv? (string-ref s nx) #\newline))
       (add! (mk 'hard-break pos (add1 nx) #f (list (token 'hard-break-marker pos nx))))
       (skip-line-indent (add1 nx))]
      [(and (< nx n) (ascii-punctuation? (string-ref s nx)))
       (add-text! pos (add1 nx) (string (string-ref s nx)) (list (token 'escape pos nx)))
       (add1 nx)]
      [else (add-text! pos nx) nx]))

  ;; --- code spans ---------------------------------------------------------------------------
  (define (run-end pos ch) (let loop ([i pos]) (if (and (< i n) (eqv? (string-ref s i) ch)) (loop (add1 i)) i)))

  (define (index-backtick-runs!)
    (define h (make-hasheqv))
    (let loop ([i 0])
      (when (< i n)
        (if (eqv? (string-ref s i) #\`)
            (let ([e (run-end i #\`)])
              (hash-set! h (- e i) (cons i (hash-ref h (- e i) '())))
              (loop e))
            (loop (add1 i)))))
    (set! backtick-runs
          (for/hasheqv ([(len starts) (in-hash h)]) (values len (list->vector (reverse starts))))))

  ;; The first run of exactly `len` backticks starting at or after `from`, or #f.
  (define (find-backtick-closer len from)
    (unless backtick-runs (index-backtick-runs!))
    (define v (hash-ref backtick-runs len #f))
    (and v
         (let search ([lo 0] [hi (vector-length v)]) ; first index with start >= from
           (if (< lo hi)
               (let ([mid (quotient (+ lo hi) 2)])
                 (if (< (vector-ref v mid) from) (search (add1 mid) hi) (search lo mid)))
               (and (< lo (vector-length v)) (vector-ref v lo))))))

  (define (handle-backticks pos)
    (define open-end (run-end pos #\`))
    (define len (- open-end pos))
    (define closer (find-backtick-closer len open-end))
    (cond
      [closer
       (define raw (list->string (for/list ([c (in-string s open-end closer)])
                                   (if (eqv? c #\newline) #\space c))))
       (define rl (string-length raw))
       (define value
         (if (and (>= rl 2) (eqv? (string-ref raw 0) #\space) (eqv? (string-ref raw (sub1 rl)) #\space)
                  (not (for/and ([c (in-string raw)]) (eqv? c #\space))))
             (substring raw 1 (sub1 rl))
             raw))
       (define end (+ closer len))
       (add! (mk 'code pos end value (list (token 'code-delim pos open-end) (token 'code-delim closer end))))
       end]
      [else (add-text! pos open-end) open-end]))

  ;; --- emphasis delimiter runs ---------------------------------------------------------------
  (define (handle-delim-run pos ch)
    (define end (run-end pos ch))
    (define before (if (= pos 0) #\newline (string-ref s (sub1 pos))))
    (define after (if (= end n) #\newline (string-ref s end)))
    (define ws-before (unicode-whitespace? before))
    (define ws-after (unicode-whitespace? after))
    (define p-before (unicode-punctuation? before))
    (define p-after (unicode-punctuation? after))
    (define left (and (not ws-after) (or (not p-after) ws-before p-before)))
    (define right (and (not ws-before) (or (not p-before) ws-after p-after)))
    (define-values (can-open can-close)
      (if (eqv? ch #\_)
          (values (and left (or (not right) p-before)) (and right (or (not left) p-after)))
          (values left right)))
    (define node (add-text! pos end))
    ;; GFM strikethrough: a run of one or two tildes; longer runs are text
    (when (and (or can-open can-close) (not (and (eqv? ch #\~) (> (- end pos) 2))))
      (define d (dl ch (- end pos) (- end pos) node can-open can-close delims #f))
      (when delims (set-dl-next! delims d))
      (set! delims d))
    end)

  (define (remove-delim! d)
    (when (dl-prev d) (set-dl-next! (dl-prev d) (dl-next d)))
    (if (dl-next d) (set-dl-prev! (dl-next d) (dl-prev d)) (set! delims (dl-prev d))))

  ;; commonmark.js processEmphasis: match closers left to right with the nearest eligible
  ;; opener above `bottom`, honoring the rule of 3; openers-bottom keeps it linear.
  (define (process-emphasis! bottom)
    (unless (eq? delims bottom) (process-emphasis-above! bottom)))

  (define (process-emphasis-above! bottom)
    (define openers-bottom (make-vector 20 bottom))
    (define first-closer
      (and delims (not (eq? delims bottom))
           (let loop ([d delims]) (if (eq? (dl-prev d) bottom) d (loop (dl-prev d))))))
    (let loop ([closer first-closer])
      (when closer
        (cond
          [(not (dl-can-close? closer)) (loop (dl-next closer))]
          [else
           (define ch (dl-char closer))
           (define tilde? (eqv? ch #\~))
           (define idx (+ (case ch [(#\_) 2] [(#\*) 8] [else 14]) (if (dl-can-open? closer) 3 0) (modulo (dl-orig closer) 3)))
           (define limit (vector-ref openers-bottom idx))
           (define opener
             (let find ([o (dl-prev closer)])
               (cond
                 [(or (not o) (eq? o bottom) (eq? o limit)) #f]
                 [(and (eqv? (dl-char o) ch) (dl-can-open? o)
                       (if tilde?
                           (= (dl-count o) (dl-count closer)) ; tildes pair by equal length
                           (not (and (or (dl-can-open? closer) (dl-can-close? o))
                                     (not (= 0 (modulo (dl-orig closer) 3)))
                                     (= 0 (modulo (+ (dl-orig o) (dl-orig closer)) 3))))))
                  o]
                 [else (find (dl-prev o))])))
           (cond
             [opener
              (define use (cond [tilde? (dl-count closer)]
                                [(and (>= (dl-count closer) 2) (>= (dl-count opener) 2)) 2]
                                [else 1]))
              (define onode (dl-node opener))
              (define cnode (dl-node closer))
              (define o-used (- (nd-end onode) use))
              (define c-used (+ (nd-start cnode) use))
              (define role (cond [tilde? 'strike-delim] [(= use 1) 'emph-delim] [else 'strong-delim]))
              (define e (mk (cond [tilde? 'strike] [(= use 1) 'emph] [else 'strong]) o-used c-used #f
                            (list (token role o-used (nd-end onode)) (token role (nd-start cnode) c-used))))
              (set-dl-count! opener (- (dl-count opener) use))
              (set-nd-end! onode o-used)
              (set-nd-value! onode (make-string (dl-count opener) ch))
              (set-dl-count! closer (- (dl-count closer) use))
              (set-nd-start! cnode c-used)
              (set-nd-value! cnode (make-string (dl-count closer) ch))
              (let move ([t (nd-next onode)])
                (when (and t (not (eq? t cnode)))
                  (define nx (nd-next t))
                  (unlink! t)
                  (append-child! e t)
                  (move nx)))
              (insert-after! onode e)
              ;; Delimiters between opener and closer can no longer match anything.
              (set-dl-next! opener closer)
              (set-dl-prev! closer opener)
              (when (= 0 (dl-count opener)) (unlink! onode) (remove-delim! opener))
              (cond
                [(= 0 (dl-count closer))
                 (define nx (dl-next closer))
                 (unlink! cnode)
                 (remove-delim! closer)
                 (loop nx)]
                [else (loop closer)])]
             [else
              (vector-set! openers-bottom idx (dl-prev closer))
              (define nx (dl-next closer))
              (unless (dl-can-open? closer) (remove-delim! closer))
              (loop nx)])])))
    (let clear () (when (and delims (not (eq? delims bottom))) (remove-delim! delims) (clear))))

  ;; --- brackets, links and images ----------------------------------------------------------
  (define (push-bracket! node pos image?)
    (when brackets (set-br-after?! brackets #t))
    (set! brackets (br node pos image? delims #f brackets links-formed)))

  (define (handle-open-bracket pos)
    (cond
      [(and wiki? (try-wiki pos)) => values]
      [else (push-bracket! (add-text! pos (add1 pos)) pos #f)
            (add1 pos)]))

  ;; Wiki links (design §2.3): `[[target]]`, `[[target#heading]]`, `[[target|alias]]` on one
  ;; line, nothing bracket-like inside, scanned atomically (never on the bracket stack). The
  ;; scan stops at the first `[`, `]` or line end, so a run of `[[` stays linear. Returns the
  ;; end, or #f to fall back to a plain `[`.
  (define (try-wiki pos)
    (and (< (+ pos 1) n) (eqv? (string-ref s (add1 pos)) #\[)
         (let* ([from (+ pos 2)]
                [stop (let loop ([i from]) (if (and (< i n) (not (memv (string-ref s i) '(#\[ #\] #\newline)))) (loop (add1 i)) i))])
           (and (< (add1 stop) n) (eqv? (string-ref s stop) #\]) (eqv? (string-ref s (add1 stop)) #\])
                (let* ([pipe (for/first ([i (in-range from stop)] #:when (eqv? (string-ref s i) #\|)) i)]
                       [target-end (or pipe stop)]
                       [hash (for/first ([i (in-range from target-end)] #:when (eqv? (string-ref s i) #\#)) i)]
                       [target (string-trim (substring s from (or hash target-end)))]
                       [heading (and hash (string-trim (substring s (add1 hash) target-end)))]
                       [alias (and pipe (string-trim (substring s (add1 pipe) stop)))])
                  (and (> (string-length target) 0)
                       (let ([end (+ stop 2)])
                         (add! (mk 'wiki pos end #f
                                   (append (list (token 'wiki-open pos from))
                                           (if pipe (list (token 'wiki-pipe pipe (add1 pipe))) '())
                                           (list (token 'wiki-close stop end)))
                                   (vector target (and heading (> (string-length heading) 0) heading)
                                           (and alias (> (string-length alias) 0) alias))))
                         end)))))))

  (define (handle-bang pos)
    (cond
      [(and (< (add1 pos) n) (eqv? (string-ref s (add1 pos)) #\[))
       (push-bracket! (add-text! pos (+ pos 2)) (add1 pos) #t)
       (+ pos 2)]
      [else (add-text! pos (add1 pos)) (add1 pos)]))

  ;; Tries `(dest "title")` right after `]`; returns (values end dest title tokens) or #f end.
  (define (try-inline-link after)
    (cond
      [(and (< after n) (eqv? (string-ref s after) #\())
       (define p1 (skip-spnl s (add1 after) n))
       (define-values (dest p2) (scan-link-destination s p1 n))
       (cond
         [dest
          (define p3 (skip-spnl s p2 n))
          (define-values (title p4)
            (if (> p3 p2) (scan-link-title s p3 n) (values #f p3)))
          (define p5 (if title (skip-spnl s p4 n) p3))
          (cond
            [(and (< p5 n) (eqv? (string-ref s p5) #\)))
             (values (add1 p5) dest title
                     (append (list (token 'link-dest-open after (add1 after)))
                             (if (> p2 p1) (list (token 'link-dest p1 p2)) '())
                             (if title (list (token 'link-title p3 p4)) '())
                             (list (token 'link-dest-close p5 (add1 p5)))))]
            [else (values #f #f #f #f)])]
         [else (values #f #f #f #f)])]
      [else (values #f #f #f #f)]))

  (define (lookup label) (hash-ref refmap (normalize-label label) #f))

  (define (handle-close-bracket pos)
    (define after (add1 pos))
    (define opener brackets)
    (cond
      [(not opener) (add-text! pos after) after]
      [(and (not (br-image? opener)) (> links-formed (br-links opener)))
       ;; Inactive: a link has formed inside this opener's text already.
       (set! brackets (br-prev opener))
       (add-text! pos after)
       after]
      [else
       (define-values (inline-end dest title inline-tokens) (try-inline-link after))
       ;; Reference forms, only when the inline form did not match.
       (define-values (end kind ref-dest ref-title label label-tokens)
         (cond
           [inline-end (values inline-end 'inline #f #f #f '())]
           [else
            (define label-end (and (< after n) (eqv? (string-ref s after) #\[) (scan-link-label s after n)))
            (define own-label-ok? ; shortcut/collapsed use the link text itself as the label
              (and (not (br-after? opener)) (<= (- pos (br-pos opener) 1) max-label-length)))
            (define (resolve label kind end tokens)
              (define def (and label (lookup label)))
              (if def
                  (values end kind (car def) (cadr def) label tokens)
                  (values #f #f #f #f #f '())))
            (cond
              [(and label-end (> (- label-end after) 2))
               (resolve (substring s (add1 after) (sub1 label-end)) 'full label-end
                        (list (token 'link-label after label-end)))]
              [label-end ; `[]`
               (resolve (and own-label-ok? (substring s (add1 (br-pos opener)) pos)) 'collapsed label-end
                        (list (token 'link-label after label-end)))]
              [else
               (resolve (and own-label-ok? (substring s (add1 (br-pos opener)) pos)) 'shortcut after '())])]))
       (cond
         [end
          (define image? (br-image? opener))
          (define onode (br-node opener))
          (define tokens ; in position order, as every node's tokens are
            (append (list (token 'link-open (nd-start onode) (nd-end onode)) (token 'link-close pos after))
                    (if inline-end inline-tokens label-tokens)))
          (define node (mk (if image? 'image 'link) (nd-start onode) end #f tokens
                           (vector kind (if inline-end dest ref-dest) (if inline-end title ref-title) label)))
          (let move ([t (nd-next onode)])
            (when t
              (define nx (nd-next t))
              (unlink! t)
              (append-child! node t)
              (move nx)))
          (add! node)
          (process-emphasis! (br-bottom opener))
          (set! brackets (br-prev opener))
          (unlink! onode)
          (unless image? (set! links-formed (add1 links-formed)))
          end]
         [else
          (set! brackets (br-prev opener))
          (add-text! pos after)
          after])]))

  ;; --- `<`: autolinks and raw HTML -----------------------------------------------------------
  (define (find-closer kind needle from)
    (define known-absent (hash-ref html-absent kind #f))
    (cond
      [(and known-absent (>= from known-absent)) #f]
      [else
       (define m (let ([nl (string-length needle)])
                   (let loop ([i from])
                     (cond
                       [(> (+ i nl) n) #f]
                       [(and (eqv? (string-ref s i) (string-ref needle 0))
                             (string=? (substring s i (+ i nl)) needle)) i]
                       [else (loop (add1 i))]))))
       (unless m (hash-set! html-absent kind (min from (or known-absent from))))
       (and m (+ m (string-length needle)))]))

  (define (starts-with? pos str)
    (define e (+ pos (string-length str)))
    (and (<= e n) (string=? (substring s pos e) str)))

  (define (ascii-letter? c) (or (and (char>=? c #\a) (char<=? c #\z)) (and (char>=? c #\A) (char<=? c #\Z))))

  ;; End of a raw HTML construct starting at `pos` (s[pos] = `<`), or #f.
  (define (scan-raw-html pos)
    (define c1 (and (< (add1 pos) n) (string-ref s (add1 pos))))
    (cond
      [(not c1) #f]
      [(ascii-letter? c1) (let ([m (regexp-match-positions rx-open-tag s pos)]) (and m (cdar m)))]
      [(eqv? c1 #\/) (let ([m (regexp-match-positions rx-close-tag s pos)]) (and m (cdar m)))]
      [(eqv? c1 #\?) (find-closer 'pi "?>" (+ pos 2))]
      [(starts-with? pos "<!--")
       (cond [(starts-with? pos "<!-->") (+ pos 5)]
             [(starts-with? pos "<!--->") (+ pos 6)]
             [else (find-closer 'comment "-->" (+ pos 4))])]
      [(starts-with? pos "<![CDATA[") (find-closer 'cdata "]]>" (+ pos 9))]
      [(and (eqv? c1 #\!) (< (+ pos 2) n) (ascii-letter? (string-ref s (+ pos 2))))
       (find-closer 'declaration ">" (+ pos 2))]
      [else #f]))

  (define (handle-less-than pos)
    (define uri (regexp-match-positions rx-autolink-uri s pos))
    (define email (and (not uri) (regexp-match-positions rx-autolink-email s pos)))
    (cond
      [(or uri email)
       (define end (cdar (or uri email)))
       (define raw (substring s (add1 pos) (sub1 end)))
       (define node (mk 'link pos end #f
                        (list (token 'autolink-bracket pos (add1 pos)) (token 'autolink-bracket (sub1 end) end))
                        (vector 'autolink (if uri raw (string-append "mailto:" raw)) #f #f)))
       (append-child! node (mk 'text (add1 pos) (sub1 end) raw))
       (add! node)
       end]
      [(scan-raw-html pos)
       => (lambda (end) (add! (mk 'html pos end #f (list (token 'html pos end)))) end)]
      [else (add-text! pos (add1 pos)) (add1 pos)]))

  ;; --- entities ------------------------------------------------------------------------------
  (define (handle-ampersand pos)
    (define-values (decoded end) (match-entity s pos n))
    (cond
      [decoded (add-text! pos end decoded (list (token 'entity pos end))) end]
      [else (add-text! pos (add1 pos)) (add1 pos)]))

  ;; --- main loop -----------------------------------------------------------------------------
  (let loop ([pos 0])
    (when (< pos n)
      (loop
       (case (string-ref s pos)
         [(#\newline) (handle-newline pos)]
         [(#\\) (handle-backslash pos)]
         [(#\`) (handle-backticks pos)]
         [(#\* #\_ #\~) (handle-delim-run pos (string-ref s pos))] ; `~` only special with strike
         [(#\[) (handle-open-bracket pos)]
         [(#\!) (handle-bang pos)]
         [(#\]) (handle-close-bracket pos)]
         [(#\<) (handle-less-than pos)]
         [(#\&) (handle-ampersand pos)]
         [else (scan-text pos)]))))
  (process-emphasis! #f)
  (define frozen (freeze-children root s opts #f))
  (if (and (eq? (inline-options-kind opts) 'heading) (extension-set-keywords ext))
      (split-state-keyword frozen s (inline-options-heading-keywords opts))
      frozen))

;; Heading keywords (design §2.3): a first text node at the content's start beginning with a
;; configured keyword and a space becomes a `state-keyword` and the rest of the text. (The block
;; phase sets `heading-keyword` from the same test on the content string.)
(define (split-state-keyword xs s keywords)
  (define kw (heading-keyword-of s keywords))
  (cond
    [(and kw (pair? xs) (text? (car xs)) (= 0 (inline-start (car xs)))
          (>= (inline-end (car xs)) (add1 (string-length kw))))
     (define t (car xs)) (define k (string-length kw))
     (list* (state-keyword 0 k '() kw)
            (text k (inline-end t) (inline-tokens t) (substring (text-value t) k))
            (cdr xs))]
    [else xs]))

;; ============================================================================================
;; Working tree -> immutable ast.rkt nodes. Adjacent text nodes that touch (one's end is the
;; next's start) are merged: leftover delimiter characters, unmatched brackets, escapes and
;; entities join the surrounding text, keeping their `escape`/`entity` tokens. Outside links and
;; images, each merged run then goes through the literal pass (autolink literals, tags, dates).
;; ============================================================================================

(define (freeze-children p s opts in-link?)
  (let loop ([c (nd-first p)] [acc '()])
    (cond
      [(not c) (reverse acc)]
      [(eq? (nd-kind c) 'text)
       ;; Gather the maximal run of touching text siblings.
       (let run ([t (nd-next c)] [pieces (list c)])
         (if (and t (eq? (nd-kind t) 'text) (= (nd-start t) (nd-end (car pieces))))
             (run (nd-next t) (cons t pieces))
             (loop t (append (reverse (text-run s (reverse pieces) opts in-link?)) acc))))]
      [else (loop (nd-next c) (cons (freeze c s opts in-link?) acc))])))

(define (freeze c s opts in-link?)
  (define st (nd-start c)) (define e (nd-end c))
  (case (nd-kind c)
    [(soft-break) (soft-break st e '())]
    [(hard-break) (hard-break st e (nd-tokens c))]
    [(code) (code-span st e (nd-tokens c) (nul->replacement (nd-value c)))]
    [(html) (raw-html st e (nd-tokens c))]
    [(emph) (emph st e (nd-tokens c) (freeze-children c s opts in-link?))]
    [(strong) (strong st e (nd-tokens c) (freeze-children c s opts in-link?))]
    [(strike) (strike st e (nd-tokens c) (freeze-children c s opts in-link?))]
    [(wiki) (let ([d (nd-data c)]) (wiki-link st e (nd-tokens c) (vector-ref d 0) (vector-ref d 1) (vector-ref d 2)))]
    [(link image)
     (define d (nd-data c))
     ((if (eq? (nd-kind c) 'link) link image)
      st e (nd-tokens c) (vector-ref d 0) (vector-ref d 1) (vector-ref d 2) (freeze-children c s opts #t)
      (vector-ref d 3))]
    [else (error 'freeze "unexpected inline kind ~a" (nd-kind c))]))

;; One run of touching text pieces -> text nodes, with autolink literals, tags and dates cut
;; out of it when their extensions are on (design §2.3). Matches are found in the source
;; (content) string and never cross an escape or entity (whose pieces' values differ from their
;; source), so every other piece's value is its source slice and splitting is exact.
(define (text-run s pieces opts in-link?)
  (define ext (inline-options-extensions opts))
  (define S (nd-start (car pieces)))
  (define E (nd-end (last pieces)))
  (define (text-between x y) ; the text node for [x, y), which never splits a token piece
    (define-values (vals toks)
      (for/fold ([vals '()] [toks '()]) ([p (in-list pieces)] #:when (and (< (nd-start p) y) (> (nd-end p) x)))
        (values (cons (if (null? (nd-tokens p))
                          (substring s (max x (nd-start p)) (min y (nd-end p)))
                          (nd-value p))
                      vals)
                (append (reverse (nd-tokens p)) toks))))
    (text x y (reverse toks) (nul->replacement (apply string-append (reverse vals)))))
  (define matches
    (if (or in-link?
            (not (or (extension-set-autolink-literal ext) (extension-set-tags ext) (extension-set-dates ext))))
        '()
        (find-literals s S E
                       (for*/list ([p (in-list pieces)] #:unless (null? (nd-tokens p))) (cons (nd-start p) (nd-end p)))
                       ext (inline-options-date-keywords opts))))
  (let loop ([pos S] [ms matches] [acc '()])
    (cond
      [(null? ms) (reverse (if (< pos E) (cons (text-between pos E) acc) acc))]
      [else
       (define m (car ms))
       (loop (inline-end m) (cdr ms)
             (cons m (if (< pos (inline-start m)) (cons (text-between pos (inline-start m)) acc) acc)))])))

;; --- the literal pass ------------------------------------------------------------------------

(define (ascii-alnum? c)
  (or (and (char>=? c #\a) (char<=? c #\z)) (and (char>=? c #\A) (char<=? c #\Z)) (and (char>=? c #\0) (char<=? c #\9))))
(define (alnum? c) (or (char-alphabetic? c) (char-numeric? c)))
(define (email-local? c) (or (ascii-alnum? c) (memv c '(#\. #\+ #\- #\_))))
(define (domain-char? c) (or (alnum? c) (memv c '(#\- #\_ #\.))))
(define (digit? c) (and (char>=? c #\0) (char<=? c #\9)))

;; Matches in s[S, E), skipping `zones` (sorted (start . end) ranges of escapes and entities),
;; left to right in one pass: each position is tried as a URL (`www.`, `http://`, `https://`,
;; `ftp://`), a tag, a date (with a keyword before it) and an email address. Returns the nodes
;; (content-relative) in order.
(define (find-literals s S E zones ext date-keywords)
  (define autolink? (extension-set-autolink-literal ext))
  (define tags? (extension-set-tags ext))
  (define dates? (extension-set-dates ext))
  (define (before i) (if (= i 0) #\newline (string-ref s (sub1 i))))
  (define (url-boundary? i) (let ([c (before i)]) (or (unicode-whitespace? c) (memv c '(#\* #\_ #\~ #\()))))
  (define (starts? i limit str)
    (define e (+ i (string-length str)))
    (and (<= e limit) (string=? (substring s i e) str)))

  ;; GFM's trailing-punctuation rules: `?!.,:*_~'"` never end a link, a `)` only when it closes
  ;; a `(` inside, and `&name;` at the end is an entity reference left outside.
  (define (trim-url start end)
    (define-values (opens closes)
      (for/fold ([o 0] [c 0]) ([ch (in-string s start end)])
        (values (if (eqv? ch #\() (add1 o) o) (if (eqv? ch #\)) (add1 c) c))))
    (let loop ([end end] [closes closes])
      (if (<= end start)
          end
          (let ([c (string-ref s (sub1 end))])
            (cond
              [(memv c '(#\? #\! #\. #\, #\: #\* #\_ #\~ #\' #\")) (loop (sub1 end) closes)]
              [(and (eqv? c #\)) (> closes opens)) (loop (sub1 end) (sub1 closes))]
              [(eqv? c #\;)
               (define amp (let back ([j (- end 2)]) (if (and (>= j start) (ascii-alnum? (string-ref s j))) (back (sub1 j)) j)))
               (if (and (>= amp start) (< amp (- end 2)) (eqv? (string-ref s amp) #\&))
                   (loop amp closes)
                   (loop (sub1 end) closes))]
              [else end])))))

  ;; segments of alphanumerics, `-` and `_` separated by periods; at least one period when
  ;; `need-period?`; no underscore in the last two segments
  (define (valid-domain? d need-period?)
    (define segs (regexp-split #rx"[.]" d))
    (and (> (string-length d) 0)
         (or (not need-period?) (> (length segs) 1))
         (let ([last2 (take-right segs (min 2 (length segs)))])
           (not (for/or ([g (in-list last2)]) (regexp-match? #rx"_" g))))))

  (define (url-at i limit)
    (define-values (scheme-len www?)
      (cond [(starts? i limit "www.") (values 4 #t)]
            [(starts? i limit "http://") (values 7 #f)]
            [(starts? i limit "https://") (values 8 #f)]
            [(starts? i limit "ftp://") (values 6 #f)]
            [else (values #f #f)]))
    (and scheme-len (url-boundary? i)
         (let* ([d-start (if www? i (+ i scheme-len))]
                [d-end (let loop ([j (+ i scheme-len)]) (if (and (< j limit) (domain-char? (string-ref s j))) (loop (add1 j)) j))]
                [domain (let ([d (substring s d-start d-end)]) (regexp-replace #rx"[.]+$" d ""))])
           (and (valid-domain? domain (not www?))
                (let* ([raw-end (let loop ([j d-end])
                                  (if (and (< j limit) (not (unicode-whitespace? (string-ref s j))) (not (eqv? (string-ref s j) #\<)))
                                      (loop (add1 j)) j))]
                       [end (trim-url i raw-end)])
                  (and (> end (+ i scheme-len))
                       (let ([t (substring s i end)])
                         (link i end '() 'literal (if www? (string-append "http://" t) t) #f
                               (list (text i end '() t)) #f))))))))

  (define (tag-at i limit)
    (define c (before i))
    (and (or (unicode-whitespace? c) (memv c '(#\( #\[ #\{ #\" #\' #\* #\_ #\~ #\, #\; #\: #\! #\?)))
         (< (add1 i) limit) (char-alphabetic? (string-ref s (add1 i)))
         (let ([end (let loop ([j (add1 i)])
                      (if (and (< j limit) (let ([d (string-ref s j)]) (or (alnum? d) (memv d '(#\_ #\- #\/)))))
                          (loop (add1 j)) j))])
           (tag i end (list (token 'tag-hash i (add1 i))) (substring s (add1 i) end)))))

  (define (date-at i limit floor)
    (define (d k) (and (< (+ i k) limit) (digit? (string-ref s (+ i k)))))
    (and (not (alnum? (before i)))
         (d 0) (d 1) (d 2) (d 3) (< (+ i 4) limit) (eqv? (string-ref s (+ i 4)) #\-) (d 5) (d 6)
         (< (+ i 7) limit) (eqv? (string-ref s (+ i 7)) #\-) (d 8) (d 9)
         (or (= (+ i 10) (string-length s)) (not (alnum? (string-ref s (+ i 10)))))
         (let ([month (string->number (substring s (+ i 5) (+ i 7)))]
               [day (string->number (substring s (+ i 8) (+ i 10)))])
           (and (<= 1 month 12) (<= 1 day 31)))
         (let* ([kw (for/first ([k (in-list date-keywords)]
                                #:when (let ([ks (- i (string-length k) 1)])
                                         (and (>= ks floor)
                                              (string-ci=? (substring s ks i) (string-append k " "))
                                              (not (alnum? (before ks))))))
                      k)]
                [start (if kw (- i (string-length kw) 1) i)])
           (date-ref start (+ i 10) '() (substring s i (+ i 10)) kw))))

  ;; an email address whose local part is the run [i, at)
  (define (email-at i at limit)
    ;; the domain: alphanumerics, `-`, `_`, `.`; a trailing `.` is punctuation, left outside
    (define run-end (let scan ([j (add1 at)])
                      (if (and (< j limit) (let ([c (string-ref s j)]) (or (ascii-alnum? c) (memv c '(#\- #\_ #\.)))))
                          (scan (add1 j)) j)))
    (define d-end* (let back ([j run-end]) (if (and (> j (add1 at)) (eqv? (string-ref s (sub1 j)) #\.)) (back (sub1 j)) j)))
    (define domain (substring s (add1 at) d-end*))
    (and (> (string-length domain) 0)
         (regexp-match? #rx"[.]" domain)
         (not (memv (string-ref domain (sub1 (string-length domain))) '(#\- #\_)))
         (let ([t (substring s i d-end*)])
           (link i d-end* '() 'literal (string-append "mailto:" t) #f (list (text i d-end* '() t)) #f))))

  (let loop ([i S] [zones zones] [floor S] [no-email-until S] [acc '()])
    (cond
      [(>= i E) (reverse acc)]
      [(and (pair? zones) (>= i (car (car zones))))
       (if (< i (cdr (car zones)))
           (loop (cdr (car zones)) (cdr zones) (cdr (car zones)) no-email-until acc)
           (loop i (cdr zones) floor no-email-until acc))]
      [else
       (define limit (if (pair? zones) (car (car zones)) E))
       (define c (string-ref s i))
       (define m
         (or (and autolink? (memv c '(#\w #\h #\f)) (url-at i limit))
             (and tags? (eqv? c #\#) (tag-at i limit))
             (and dates? (digit? c) (date-at i limit floor))))
       (cond
         [m (loop (inline-end m) zones (inline-end m) (inline-end m) (cons m acc))]
         [(and autolink? (>= i no-email-until) (email-local? c) (not (email-local? (before i))))
          (define at (let scan ([j i]) (if (and (< j limit) (email-local? (string-ref s j))) (scan (add1 j)) j)))
          (define em (and (< at limit) (eqv? (string-ref s at) #\@) (email-at i at limit)))
          (if em
              (loop (inline-end em) zones (inline-end em) (inline-end em) (cons em acc))
              (loop (add1 i) zones floor at acc))]
         [else (loop (add1 i) zones floor no-email-until acc)])])))

;; ============================================================================================
;; Relocation through segments (design §1.3).
;; ============================================================================================

;; Maps content-relative inline trees to document offsets. A content offset inside a segment
;; maps linearly; the "\n" between two segments maps to the source line ending after the first;
;; virtual spaces (source-length 0) clamp to their segment's source-start. An end offset e maps
;; as (map (e - 1)) + 1, so an end at a line start never lands after the next line's container
;; prefix. A token that crosses a segment boundary (a raw-HTML tag or a link title spanning
;; lines) is split into one token per segment piece, so tokens never cover a container prefix.
(define (relocate-inlines inlines segments)
  (define segv (list->vector segments))
  (define nseg (vector-length segv))
  (define (seg-index c) ; last segment whose content-start <= c
    (let loop ([lo 0] [hi (sub1 nseg)])
      (if (>= lo hi)
          lo
          (let ([mid (quotient (+ lo hi 1) 2)])
            (if (<= (segment-content-start (vector-ref segv mid)) c) (loop mid hi) (loop lo (sub1 mid)))))))
  (define (map-char c)
    (define sg (vector-ref segv (seg-index c)))
    (define cs (segment-content-start sg))
    (define cl (segment-content-length sg))
    (cond
      [(= (segment-source-length sg) 0) (segment-source-start sg)]
      [(< c (+ cs cl)) (+ (segment-source-start sg) (- c cs))]
      [else (+ (segment-source-start sg) (segment-source-length sg))]))
  (define (map-end s e)
    (cond
      [(= e s) (map-char s)]
      [else
       (define sg (vector-ref segv (seg-index (sub1 e))))
       (if (and (= (segment-source-length sg) 0)
                (< (sub1 e) (+ (segment-content-start sg) (segment-content-length sg))))
           (segment-source-start sg)
           (add1 (map-char (sub1 e))))]))
  (define (reloc-token t)
    (define s (token-start t)) (define e (token-end t))
    (define si (seg-index s))
    (define sg (vector-ref segv si))
    (if (<= e (+ (segment-content-start sg) (segment-content-length sg)))
        (list (token (token-role t) (map-char s) (map-end s e)))
        ;; Crosses one or more line boundaries: one piece per segment with real source text.
        (let loop ([i si] [acc '()])
          (cond
            [(or (>= i nseg) (>= (segment-content-start (vector-ref segv i)) e))
             (if (null? acc)
                 (list (token (token-role t) (map-char s) (map-char s)))
                 (reverse acc))]
            [else
             (define g (vector-ref segv i))
             (define gs (max s (segment-content-start g)))
             (define ge (min e (+ (segment-content-start g) (segment-content-length g))))
             (loop (add1 i)
                   (if (and (< gs ge) (> (segment-source-length g) 0))
                       (cons (token (token-role t) (map-char gs) (map-end gs ge)) acc)
                       acc))]))))
  (define (reloc-tokens ts) (append-map reloc-token ts))
  (define (reloc x)
    (define s (map-char (inline-start x)))
    (define e (map-end (inline-start x) (inline-end x)))
    (define ts (reloc-tokens (inline-tokens x)))
    (cond
      [(text? x) (text s e ts (text-value x))]
      [(soft-break? x) (soft-break s e ts)]
      [(hard-break? x) (hard-break s e ts)]
      [(code-span? x) (code-span s e ts (code-span-value x))]
      [(raw-html? x) (raw-html s e ts)]
      [(emph? x) (emph s e ts (map reloc (emph-children x)))]
      [(strong? x) (strong s e ts (map reloc (strong-children x)))]
      [(strike? x) (strike s e ts (map reloc (strike-children x)))]
      [(wiki-link? x) (wiki-link s e ts (wiki-link-target x) (wiki-link-heading x) (wiki-link-alias x))]
      [(tag? x) (tag s e ts (tag-name x))]
      [(date-ref? x) (date-ref s e ts (date-ref-date x) (date-ref-keyword x))]
      [(state-keyword? x) (state-keyword s e ts (state-keyword-keyword x))]
      [(link? x) (link s e ts (link-kind x) (link-dest x) (link-title x) (map reloc (link-children x)) (link-label x))]
      [(image? x) (image s e ts (image-kind x) (image-dest x) (image-title x) (map reloc (image-children x)) (image-label x))]
      [else (error 'relocate-inlines "unexpected inline ~a" x)]))
  (if (= nseg 0) inlines (map reloc inlines)))

;; ============================================================================================
;; Inline cells (ast.rkt): the lazy `inlines` slot of paragraphs and headings.
;; ============================================================================================

;; `relative-thunk` produces the content-relative tree (mdlib-parser supplies one that goes
;; through its memo; the block phase's default calls parse-inlines).
(define (make-inline-cell content segments relative-thunk)
  (define rel (delay (relative-thunk)))
  (inline-cell content segments rel (delay (relocate-inlines (force rel) segments))))

(define empty-inline-cell (make-inline-cell "" '() (lambda () '())))

(define (cell-inlines cell) (force (inline-cell-absolute cell)))
(define (cell-relative-inlines cell) (force (inline-cell-relative cell)))
