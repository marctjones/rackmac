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
(require racket/list racket/promise
         "ast.rkt" "chars.rkt" "entities.rkt" "refs.rkt")
(provide parse-inlines relocate-inlines
         make-inline-cell cell-inlines cell-relative-inlines empty-inline-cell)

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

(define (special? c)
  (case c [(#\newline #\\ #\` #\* #\_ #\[ #\] #\! #\< #\&) #t] [else #f]))

(define rx-autolink-uri #px"^<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\u0000-\u0020]*>")
(define rx-autolink-email
  #px"^<[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:[.][a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>")
(define html-attribute
  "(?:\\s+[a-zA-Z_:][a-zA-Z0-9:._-]*(?:\\s*=\\s*(?:[^\"'=<>`\u0000-\u0020]+|'[^']*'|\"[^\"]*\"))?)")
(define rx-open-tag (pregexp (string-append "^<[A-Za-z][A-Za-z0-9-]*" html-attribute "*\\s*/?>")))
(define rx-close-tag #px"^</[A-Za-z][A-Za-z0-9-]*\\s*>")

;; Parses `s` (a leaf block's content) against `refmap` (normalized label -> (list dest title
;; node)); returns the list of inline nodes (ast.rkt structs) with content-relative offsets.
(define (parse-inlines s refmap)
  (define n (string-length s))
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
    (when (or can-open can-close)
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
    (define openers-bottom (make-vector 14 bottom))
    (define first-closer
      (and delims (not (eq? delims bottom))
           (let loop ([d delims]) (if (eq? (dl-prev d) bottom) d (loop (dl-prev d))))))
    (let loop ([closer first-closer])
      (when closer
        (cond
          [(not (dl-can-close? closer)) (loop (dl-next closer))]
          [else
           (define ch (dl-char closer))
           (define idx (+ (if (eqv? ch #\_) 2 8) (if (dl-can-open? closer) 3 0) (modulo (dl-orig closer) 3)))
           (define limit (vector-ref openers-bottom idx))
           (define opener
             (let find ([o (dl-prev closer)])
               (cond
                 [(or (not o) (eq? o bottom) (eq? o limit)) #f]
                 [(and (eqv? (dl-char o) ch) (dl-can-open? o)
                       (not (and (or (dl-can-open? closer) (dl-can-close? o))
                                 (not (= 0 (modulo (dl-orig closer) 3)))
                                 (= 0 (modulo (+ (dl-orig o) (dl-orig closer)) 3)))))
                  o]
                 [else (find (dl-prev o))])))
           (cond
             [opener
              (define use (if (and (>= (dl-count closer) 2) (>= (dl-count opener) 2)) 2 1))
              (define onode (dl-node opener))
              (define cnode (dl-node closer))
              (define o-used (- (nd-end onode) use))
              (define c-used (+ (nd-start cnode) use))
              (define role (if (= use 1) 'emph-delim 'strong-delim))
              (define e (mk (if (= use 1) 'emph 'strong) o-used c-used #f
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
    (push-bracket! (add-text! pos (add1 pos)) pos #f)
    (add1 pos))

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
          (define tokens
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
         [(#\* #\_) (handle-delim-run pos (string-ref s pos))]
         [(#\[) (handle-open-bracket pos)]
         [(#\!) (handle-bang pos)]
         [(#\]) (handle-close-bracket pos)]
         [(#\<) (handle-less-than pos)]
         [(#\&) (handle-ampersand pos)]
         [else (scan-text pos)]))))
  (process-emphasis! #f)
  (freeze-children root))

;; ============================================================================================
;; Working tree -> immutable ast.rkt nodes. Adjacent text nodes that touch (one's end is the
;; next's start) are merged: leftover delimiter characters, unmatched brackets, escapes and
;; entities join the surrounding text, keeping their `escape`/`entity` tokens.
;; ============================================================================================

(define (freeze-children p)
  (let loop ([c (nd-first p)] [acc '()])
    (cond
      [(not c) (reverse acc)]
      [(eq? (nd-kind c) 'text)
       ;; Gather the maximal run of touching text siblings.
       (let run ([t (nd-next c)] [end (nd-end c)] [vals (list (nd-value c))] [tokens (reverse (nd-tokens c))])
         (if (and t (eq? (nd-kind t) 'text) (= (nd-start t) end))
             (run (nd-next t) (nd-end t) (cons (nd-value t) vals) (append (reverse (nd-tokens t)) tokens))
             (loop t (cons (text (nd-start c) end (reverse tokens) (apply string-append (reverse vals))) acc))))]
      [else (loop (nd-next c) (cons (freeze c) acc))])))

(define (sorted-tokens node) (sort (nd-tokens node) < #:key token-start))

(define (freeze c)
  (define s (nd-start c)) (define e (nd-end c))
  (case (nd-kind c)
    [(soft-break) (soft-break s e '())]
    [(hard-break) (hard-break s e (nd-tokens c))]
    [(code) (code-span s e (nd-tokens c) (nd-value c))]
    [(html) (raw-html s e (nd-tokens c))]
    [(emph) (emph s e (nd-tokens c) (freeze-children c))]
    [(strong) (strong s e (nd-tokens c) (freeze-children c))]
    [(link image)
     (define d (nd-data c))
     ((if (eq? (nd-kind c) 'link) link image)
      s e (sorted-tokens c) (vector-ref d 0) (vector-ref d 1) (vector-ref d 2) (freeze-children c)
      (vector-ref d 3))]
    [else (error 'freeze "unexpected inline kind ~a" (nd-kind c))]))

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
