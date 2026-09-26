#lang racket/base
;; Phase 1 (design §2.1): the CommonMark block algorithm, following the spec's appendix
;; ("A parsing strategy") as cmark implements it. Produces the immutable tree of ast.rkt
;; structs, with segments (§1.3), a line index, and the reference-definition map (§1.4).
;; Paragraphs and headings get a lazy inline-cell (ast.rkt): their inline content is parsed
;; (inlines.rkt) only once the block phase, and so the refmap, is complete (design §1.4).
(require racket/string racket/list racket/match
         "chars.rkt" "ast.rkt" "lines.rkt" "refs.rkt" "inlines.rkt")
(provide parse-blocks)

;; ============================================================================================
;; Mutable parse tree (converted to immutable ast.rkt structs by `finalize` at the end).
;; ============================================================================================

;; kind: 'document 'block-quote 'list 'list-item 'paragraph 'heading 'thematic-break
;;       'code-block 'html-block
;; data: a mutable hasheq of kind-specific fields (built from an association list); see the
;; `mdata` helpers below for the keys each kind uses.
(struct mblk (kind [start #:mutable] [end #:mutable] [children #:mutable] [open? #:mutable]
              [data #:mutable]))

;; A small mutable association list updated in place: a growing alist (a fresh pair per set)
;; made deeply nested lists quadratic in lines x depth x alist length, and a hash table per block
;; cost more to allocate than the whole block. A block has at most a handful of keys.
(define (mdata-ref b key [default #f])
  (let loop ([ps (mblk-data b)])
    (cond [(null? ps) default]
          [(eq? (mcar (mcar ps)) key) (mcdr (mcar ps))]
          [else (loop (mcdr ps))])))
(define (mdata-set! b key val)
  (let loop ([ps (mblk-data b)])
    (cond [(null? ps) (set-mblk-data! b (mcons (mcons key val) (mblk-data b)))]
          [(eq? (mcar (mcar ps)) key) (set-mcdr! (mcar ps) val)]
          [else (loop (mcdr ps))])))

(define (make-mblk kind start data)
  (mblk kind start start '() #t
        (for/fold ([acc '()]) ([p (in-list (reverse data))]) (mcons (mcons (car p) (cdr p)) acc))))

;; Appends `child` to `parent`, closing parent's current last (open) child first, unless that
;; child *is* the one being reused for list continuation (callers handle that by not going
;; through here in that case -- see `open-list-item!`).
(define (append-child! parent child)
  (define kids (mblk-children parent))
  ;; Looseness bookkeeping (spec, "Lists": loose iff any two items are separated by a blank
  ;; line, or any item directly contains two block-level children separated by one). A
  ;; list-item's 'trailing-blank? flag (set/cleared per line, see process-line!'s wrapper)
  ;; records whether the most recent line touching it was blank.
  (cond
    [(and (eq? (mblk-kind parent) 'list-item) (pair? kids) (mdata-ref parent 'trailing-blank?))
     (mdata-set! parent 'internal-blank? #t)]
    [(and (eq? (mblk-kind parent) 'list) (eq? (mblk-kind child) 'list-item) (pair? kids)
          (mdata-ref (car kids) 'trailing-blank?))
     (mdata-set! parent 'loose? #t)])
  (when (and (pair? kids) (mblk-open? (car kids)))
    (close-block! (car kids)))
  (set-mblk-children! parent (cons child kids)))

(define (close-block! b) (set-mblk-open?! b #f))

;; Records a markup token (design §1.2) on a block: quote markers, list markers, heading markers,
;; setext underlines, fences, info strings, reference-definition parts.
(define (add-token! b role start end)
  (when (< start end) (mdata-set! b 'tokens (cons (token role start end) (mdata-ref b 'tokens '())))))

;; A block's tokens in position order: each is recorded after the ones before it on its line
;; and lines come in order, so reversing the recorded list suffices.
(define (block-tokens-of b) (reverse (mdata-ref b 'tokens '())))

;; Sets `end` on every block in `path` (a list root..tip) to `end`.
(define (touch-path! path end)
  (for ([b (in-list path)]) (set-mblk-end! b end)))

;; The open path from `doc` to the current tip: repeatedly take the most-recent child while it
;; is open (only the last child of any container can be open).
(define (open-path-of doc)
  (let loop ([b doc] [acc (list doc)])
    (define kids (mblk-children b))
    (if (and (pair? kids) (mblk-open? (car kids)))
        (loop (car kids) (cons (car kids) acc))
        (reverse acc))))

;; ============================================================================================
;; Column-tracking helpers built on chars.rkt's tab-aware `advance-columns`.
;; ============================================================================================

;; Scans forward through spaces/tabs (fully consuming any tabs) until a non-space/tab char or
;; line-end. Returns (values offset column) of the first non-space/tab position reached.
(define (scan-indent source offset column line-end)
  (let loop ([offset offset] [column column])
    (if (>= offset line-end)
        (values offset column)
        (let ([ch (string-ref source offset)])
          (cond
            [(eqv? ch #\space) (loop (add1 offset) (add1 column))]
            [(eqv? ch #\tab) (loop (add1 offset) (+ column (tab-stop column)))]
            [else (values offset column)])))))

;; #t if `offset` sits in the middle of a (partially consumed) tab at `column`.
(define (mid-tab? source offset column line-end)
  (and (< offset line-end) (eqv? (string-ref source offset) #\tab) (not (= 0 (modulo column 4)))))

;; The (source-start . virtual-indent) pair for a leaf's content starting at (offset, column):
;; if we're mid-tab, the leaf's content begins after the tab, prefixed by that tab's remaining
;; (virtual) columns; otherwise it begins exactly here with no virtual indent (design §1.3).
(define (leaf-line-start source offset column line-end)
  (if (mid-tab? source offset column line-end)
      (values (add1 offset) (tab-stop column))
      (values offset 0)))

;; A paragraph line's content (first line or continuation, lazy or not) starts after ALL of its
;; leading whitespace, however much there is (spec, "Paragraphs": "the paragraph's raw content
;; is formed by concatenating the lines and removing initial ... whitespace" -- applied per
;; line, since indentation before a paragraph line is never significant once we've established
;; it isn't an indented code block, a new block start, or a container prefix).
(define (paragraph-line-start source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (leaf-line-start source ns nc line-end))

;; ============================================================================================
;; Container matching (phase 1): does an already-open container continue on this line?
;; ============================================================================================

;; Block quote: 0-3 spaces indent, '>', optional one space/tab (one column). Returns (values
;; marker-offset new-offset new-column), marker-offset #f when the line does not continue it.
(define (match-blockquote source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (cond
    [(and (<= (- nc column) 3) (< ns line-end) (eqv? (string-ref source ns) #\>))
     (define after (add1 ns)) (define after-col (add1 nc))
     (if (and (< after line-end) (space-or-tab? (string-ref source after)))
         (let-values ([(o2 c2 p2) (advance-columns source after after-col 1 line-end)])
           (values ns o2 c2))
         (values ns after after-col))]
    [else (values #f offset column)]))

;; List item continuation: blank line (matches trivially), or indentation >= content-column.
;; A "dead" item (one whose first line was blank and that saw a further blank line before any
;; real content) never matches again (spec: such an item's content stops right there, and later
;; indented material is not pulled into it -- e.g. "-\n\n  foo" leaves "foo" outside the list).
;; `first-non-blank` maps an offset to the first non-space/tab position at or after it (memoized
;; per line by match-containers): rescanning the whole indentation at every level made 1,000
;; nested items over 1,000 lines cubic (tests/pathological-test.rkt, "deeply nested lists").
(define (match-list-item source offset column line-end item first-non-blank)
  (define content-column (mdata-ref item 'content-column))
  (cond
    [(mdata-ref item 'dead?) (values #f offset column #f)]
    [(>= (first-non-blank offset) line-end)
     (when (and (mdata-ref item 'blank-start?) (null? (mblk-children item)))
       (mdata-set! item 'dead? #t))
     (values #t offset column #t)] ; blank remainder: matches, contributes nothing
    [else
     ;; advance-columns stops at the first non-space/tab, so reaching content-column means the
     ;; indentation is at least that deep (what scan-indent's full column told us before).
     (define-values (o2 c2 p2) (advance-columns source offset column (- content-column column) line-end))
     (if (>= c2 content-column)
         (values #t o2 c2 #f)
         (values #f offset column #f))]))

;; Runs the generic container-matching loop over `containers` (a list of mblk, all 'block-quote,
;; 'list, or 'list-item -- 'list itself always "matches", contributing nothing). Returns
;; (values matched-count offset column blank-stop?).
(define (match-containers containers source line-start content-end)
  (define memo-from -1) (define memo-result -1)
  (define (first-non-blank offset)
    (unless (<= memo-from offset memo-result)
      (set! memo-from offset)
      (set! memo-result (let scan ([i offset])
                          (if (and (< i content-end) (space-or-tab? (string-ref source i))) (scan (add1 i)) i))))
    memo-result)
  (let loop ([cs containers] [i 0] [offset line-start] [column 0])
    (cond
      [(null? cs) (values i offset column #f)]
      [else
       (define c (car cs))
       (case (mblk-kind c)
         [(list) (loop (cdr cs) (add1 i) offset column)]
         [(block-quote)
          (define-values (marker o2 c2) (match-blockquote source offset column content-end))
          (cond [marker (add-token! c 'quote-marker marker (add1 marker))
                        (loop (cdr cs) (add1 i) o2 c2)]
                [else (values i offset column #f)])]
         [(list-item)
          (define-values (ok? o2 c2 blank?)
            (match-list-item source offset column content-end c first-non-blank))
          ;; A blank line matches trivially and contributes no columns, but still has to keep
          ;; walking into any deeper containers (a nested list-item several levels down matches
          ;; the same blank line just as trivially) -- stopping here would wrongly look like a
          ;; mismatch at every level below this one.
          (cond [(not ok?) (values i offset column #f)]
                [blank? (loop (cdr cs) (add1 i) offset column)]
                [else (loop (cdr cs) (add1 i) o2 c2)])]
         [else (values i offset column #f)])])))

;; ============================================================================================
;; New-block-start detection (phase 2).
;; ============================================================================================

;; Scans in place: a substring here copied the rest of the line at every nesting level, which
;; made a 50,000-deep `>>>>...` line quadratic (tests/pathological-test.rkt).
(define (blank-from? source offset line-end)
  (let loop ([i offset])
    (or (>= i line-end) (and (space-or-tab? (string-ref source i)) (loop (add1 i))))))

;; ATX heading: 0-3 indent, 1-6 '#', then space/tab/eol. Returns (list level content-start) or #f.
(define (try-atx source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (and (<= (- nc column) 3)
       (let loop ([i ns] [level 0])
         (cond
           [(and (< i line-end) (eqv? (string-ref source i) #\#) (< level 6))
            (loop (add1 i) (add1 level))]
           [(= level 0) #f]
           [(and (< i line-end) (not (space-or-tab? (string-ref source i)))) #f]
           [else (list level i)]))))

;; Thematic break: 0-3 indent, 3+ of the same *, _, or -, optionally interspersed with spaces/tabs.
(define (try-thematic-break source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (and (<= (- nc column) 3) (< ns line-end)
       (let ([c (string-ref source ns)])
         (and (memv c '(#\* #\_ #\-))
              (let loop ([i ns] [count 0])
                (cond
                  [(>= i line-end) (>= count 3)]
                  [(eqv? (string-ref source i) c) (loop (add1 i) (add1 count))]
                  [(space-or-tab? (string-ref source i)) (loop (add1 i) count)]
                  [else #f]))))))

;; Fenced code open: 0-3 indent, 3+ backticks or tildes; backtick fences forbid backticks in the
;; info string. Returns (list fence-char fence-length fence-indent info-string) or #f.
(define (try-fence-open source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (and (<= (- nc column) 3) (< ns line-end)
       (let ([c (string-ref source ns)])
         (and (memv c '(#\` #\~))
              (let loop ([i ns] [count 0])
                (cond
                  [(and (< i line-end) (eqv? (string-ref source i) c)) (loop (add1 i) (add1 count))]
                  [(< count 3) #f]
                  [else
                   (define info (string-trim (substring source i line-end)))
                   (and (or (eqv? c #\~) (not (regexp-match? #rx"`" info)))
                        (list c count (- nc column) info))]))))))

;; Does the current line close an open fence of `fence-char`/`fence-length`?
(define (fence-closes? source offset column line-end fence-char fence-length)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (and (<= (- nc column) 3) (< ns line-end) (eqv? (string-ref source ns) fence-char)
       (let loop ([i ns] [count 0])
         (cond
           [(and (< i line-end) (eqv? (string-ref source i) fence-char)) (loop (add1 i) (add1 count))]
           [(< count fence-length) #f]
           [else (blank-from? source i line-end)]))))

;; List marker (bullet or ordered). Returns (list kind delim start-number after-offset after-col
;; marker-col) or #f. kind: 'bullet or 'ordered. marker-col is the column of the marker's own
;; first character (needed to compute the content-column of an item whose first line is blank).
(define (try-list-marker source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (and (<= (- nc column) 3) (< ns line-end)
       (let ([ch (string-ref source ns)])
         (cond
           [(memv ch '(#\- #\+ #\*))
            (define after (add1 ns)) (define after-col (add1 nc))
            (and (or (>= after line-end) (space-or-tab? (string-ref source after)))
                 (list 'bullet ch #f after after-col nc))]
           [(char-numeric? ch)
            (let loop ([i ns] [digits 1])
              (cond
                [(and (< (add1 i) line-end) (char-numeric? (string-ref source (add1 i))) (< digits 9))
                 (loop (add1 i) (add1 digits))]
                [else
                 (define delim-pos (add1 i))
                 (and (< delim-pos line-end) (memv (string-ref source delim-pos) '(#\. #\)))
                      (let* ([after (add1 delim-pos)] [after-col (+ nc digits 1)])
                        (and (or (>= after line-end) (space-or-tab? (string-ref source after)))
                             (list 'ordered (string-ref source delim-pos)
                                   (string->number (substring source ns delim-pos))
                                   after after-col nc))))]))]
           [else #f]))))

;; The content-column for a fresh list item, given the position right after its marker
;; (after-offset, after-col -- the column right after the marker, delimiter included).
(define (list-content-column source after-offset after-col line-end)
  (define-values (fns fnc) (scan-indent source after-offset after-col line-end))
  (define spaces-after (- fnc after-col))
  (cond
    [(>= fns line-end) (add1 after-col)] ; nothing follows: empty item, content-column = marker-end+1
    [(> spaces-after 4) (add1 after-col)]
    [else fnc]))

;; --- HTML block start conditions (spec, "HTML blocks") -----------------------------------------

(define html-type6-tags
  '("address" "article" "aside" "base" "basefont" "blockquote" "body" "caption" "center" "col"
    "colgroup" "dd" "details" "dialog" "dir" "div" "dl" "dt" "fieldset" "figcaption" "figure"
    "footer" "form" "frame" "frameset" "h1" "h2" "h3" "h4" "h5" "h6" "head" "header" "hr" "html"
    "iframe" "legend" "li" "link" "main" "menu" "menuitem" "nav" "noframes" "ol" "optgroup"
    "option" "p" "param" "search" "section" "summary" "table" "tbody" "td" "tfoot" "th" "thead"
    "title" "tr" "track" "ul"))

(define rx-html1-start (pregexp "(?i:^ {0,3}<(script|pre|style|textarea)(?:[ \t>]|$))"))
(define rx-html1-end (pregexp "(?i:</(script|pre|style|textarea)>)"))
(define rx-html2-start (pregexp "^ {0,3}<!--"))
(define rx-html2-end (pregexp "-->"))
(define rx-html3-start (pregexp "^ {0,3}<[?]"))
(define rx-html3-end (pregexp "[?]>"))
(define rx-html4-start (pregexp "(?i:^ {0,3}<![A-Za-z])"))
(define rx-html4-end (pregexp ">"))
(define rx-html5-start (pregexp "^ {0,3}<!\\[CDATA\\["))
(define rx-html5-end (pregexp "\\]\\]>"))
(define rx-html6-start
  (pregexp (format "(?i:^ {0,3}</?(~a)(?:[ \t>]|/>|$))" (string-join html-type6-tags "|"))))

;; Type-7 open/closing tag grammar (spec's "Open tag"/"Closing tag" productions).
(define tagname "[A-Za-z][A-Za-z0-9-]*")
(define attr-name "[a-zA-Z_:][a-zA-Z0-9:._-]*")
(define unquoted-value "[^ \t\r\n\"'=<>`]+")
(define single-quoted "'[^']*'")
(define double-quoted "\"[^\"]*\"")
(define attr-value (format "(?:~a|~a|~a)" unquoted-value single-quoted double-quoted))
(define attr-value-spec (format "[ \t\r\n]*=[ \t\r\n]*~a" attr-value))
(define attribute (format "[ \t\r\n]+~a(?:~a)?" attr-name attr-value-spec))
(define open-tag (format "<~a(?:~a)*[ \t\r\n]*/?>" tagname attribute))
(define close-tag (format "</~a[ \t\r\n]*>" tagname))
(define rx-html7-start
  (pregexp (format "(?i:^ {0,3}(?:~a|~a)[ \t]*$)" open-tag close-tag)))

;; Returns the html-block kind (1-7) that starts at (offset, column) on this line, given whether
;; a paragraph is currently open (kind 7 cannot interrupt a paragraph), or #f.
(define (try-html-block-start source offset column line-end tip-is-paragraph?)
  ;; Every start condition is up to 3 spaces then `<`: check that before copying the line.
  (define lt (let loop ([i offset] [k 0])
               (cond [(or (>= i line-end) (> k 3)) #f]
                     [(eqv? (string-ref source i) #\space) (loop (add1 i) (add1 k))]
                     [else (eqv? (string-ref source i) #\<)])))
  (define s (if lt (substring source offset line-end) ""))
  (cond
    [(not lt) #f]
    [(regexp-match? rx-html1-start s) 1]
    [(regexp-match? rx-html2-start s) 2]
    [(regexp-match? rx-html3-start s) 3]
    [(regexp-match? rx-html4-start s) 4]
    [(regexp-match? rx-html5-start s) 5]
    [(regexp-match? rx-html6-start s) 6]
    [(and (not tip-is-paragraph?) (regexp-match? rx-html7-start s)) 7]
    [else #f]))

(define (html-block-end-met? source offset line-end kind)
  (define s (substring source offset line-end))
  (case kind
    [(1) (regexp-match? rx-html1-end s)]
    [(2) (regexp-match? rx-html2-end s)]
    [(3) (regexp-match? rx-html3-end s)]
    [(4) (regexp-match? rx-html4-end s)]
    [(5) (regexp-match? rx-html5-end s)]
    [else #f])) ; 6 and 7 end on the next blank line, checked by the caller

;; Setext underline: 0-3 indent, then a run of all '=' or all '-' (no internal spaces -- unlike
;; a thematic break, spec: "without any internal spaces"), then trailing spaces/tabs only.
;; Returns 1 (for '=') or 2 (for '-'), or #f.
(define (try-setext source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (and (<= (- nc column) 3) (< ns line-end)
       (let ([c (string-ref source ns)])
         (and (memv c '(#\= #\-))
              (let loop ([i ns])
                (cond
                  [(and (< i line-end) (eqv? (string-ref source i) c)) (loop (add1 i))]
                  [(blank-from? source i line-end) (if (eqv? c #\=) 1 2)]
                  [else #f]))))))

;; A descriptor for whatever new block would start at (offset, column), or #f if nothing would
;; (i.e., it's ordinary paragraph text). `tip-is-paragraph?` disables constructs that cannot
;; interrupt a paragraph (indented code, HTML type 7, ordered lists not starting at 1, and list
;; items that begin with a blank line). Setext headings are handled by the caller, not here
;; (they never apply across a lazy-continuation mismatch -- spec, "Setext headings").
(define (find-new-block-start source offset column line-end tip-is-paragraph?)
  (cond
    [(and (not tip-is-paragraph?)
          (let-values ([(ns nc) (scan-indent source offset column line-end)])
            (and (>= (- nc column) 4) (< ns line-end))))
     (list 'indented-code)]
    [(match-blockquote-start? source offset column line-end) (list 'block-quote)]
    [(try-atx source offset column line-end) => (lambda (d) (cons 'atx d))]
    [(try-fence-open source offset column line-end) => (lambda (d) (cons 'fence d))]
    [(try-html-block-start source offset column line-end tip-is-paragraph?)
     => (lambda (k) (list 'html k))]
    [(try-thematic-break source offset column line-end) (list 'thematic-break)]
    [(try-list-marker source offset column line-end)
     => (lambda (d)
          (match-define (list kind delim start-number after after-col marker-col) d)
          (define-values (fns fnc) (scan-indent source after after-col line-end))
          (define blank-first-line? (>= fns line-end))
          (cond
            [(and tip-is-paragraph? blank-first-line?) #f] ; can't interrupt with a blank item
            [(and tip-is-paragraph? (eq? kind 'ordered) (not (equal? start-number 1))) #f]
            [else (list 'list kind delim start-number after after-col marker-col)]))]
    [else #f]))

(define (match-blockquote-start? source offset column line-end)
  (define-values (ns nc) (scan-indent source offset column line-end))
  (and (<= (- nc column) 3) (< ns line-end) (eqv? (string-ref source ns) #\>)))

;; ============================================================================================
;; Building leaf lines and segments.
;; ============================================================================================

;; Appends a (start len virtual-indent) triple to a leaf's accumulated 'lines data field.
(define (add-line! b start end vindent)
  (mdata-set! b 'lines (cons (list start (- end start) vindent) (mdata-ref b 'lines '()))))

(define (leaf-lines b) (reverse (mdata-ref b 'lines '())))

;; Builds §1.3 segments and the joined content string from a leaf's accumulated lines. The
;; content is written into one string of the final length (per-line substrings joined afterwards
;; cost twice the allocation, and this runs for every leaf on every keystroke, design §3.1).
(define (build-segments+content source lines)
  (define total
    (let loop ([ls lines] [n 0])
      (if (null? ls) (max 0 (sub1 n)) (loop (cdr ls) (+ n (cadr (car ls)) (caddr (car ls)) 1)))))
  (define content (make-string total #\space))
  (let loop ([lines lines] [content-pos 0] [segs '()])
    (cond
      [(null? lines) (values (reverse segs) content)]
      [else
       (define l (car lines))
       (define src-start (car l)) (define src-len (cadr l)) (define vindent (caddr l))
       (define text-pos (+ content-pos vindent))
       (string-copy! content text-pos source src-start (+ src-start src-len))
       (define next (+ text-pos src-len))
       (when (< next total) (string-set! content next #\newline))
       (define segs2
         (if (> vindent 0)
             (list* (segment text-pos src-len src-start src-len)
                    (segment content-pos vindent src-start 0)
                    segs)
             (cons (segment content-pos src-len src-start src-len) segs)))
       (loop (cdr lines) (add1 next) segs2)])))

;; Strips trailing spaces/tabs from the LAST accumulated line only (spec, "Paragraphs": raw
;; content has "final whitespace" removed; a non-last line's trailing spaces are left for the
;; inline phase's hard-break rule to see).
(define (trim-trailing-line-ws source lines)
  (if (null? lines)
      lines
      (let* ([rl (reverse lines)])
        (match-define (list s len v) (car rl))
        (define new-len
          (let loop ([len len])
            (if (and (> len 0) (space-or-tab? (string-ref source (+ s (sub1 len)))))
                (loop (sub1 len))
                len)))
        (reverse (cons (list s new-len v) (cdr rl))))))

;; ============================================================================================
;; The main per-line driver.
;; ============================================================================================

(define (process-line! doc source lr)
  (define prefix-end (box (line-record-start lr)))
  (process-line-inner! doc source lr prefix-end)
  ;; Catch-all: whatever got opened, continued, or closed above, every block on the freshly
  ;; recomputed open path (down to the new tip -- which reflects any newly opened containers or
  ;; leaf) legitimately spans through this line's content-end. Individual branches above also
  ;; touch what they know they touched; this just makes it unconditional and impossible to miss.
  (define fresh-path (open-path-of doc))
  (touch-path! fresh-path (line-record-content-end lr))
  ;; Looseness bookkeeping (see append-child!): every list-item still reachable records whether
  ;; *this* line was blank, so the next thing attached to it (a sibling item, or a second child
  ;; of the same item) can tell whether a blank line came immediately before it.
  ;; A line is blank for the items below the deepest block quote it continues when nothing
  ;; follows that quote's `>` (so `> - a` / `>` / `> - b` is a loose list), and for no item
  ;; above that quote (spec example 320: `* a` / `  > b` / `  >` / `* c` stays tight), as cmark
  ;; sets last_line_blank on the innermost container only.
  (define line-blank? (blank-from? source (unbox prefix-end) (line-record-content-end lr)))
  (define deepest-quote (for/last ([b (in-list fresh-path)] #:when (eq? (mblk-kind b) 'block-quote)) b))
  (for/fold ([below-quotes? (not deepest-quote)]) ([b (in-list fresh-path)])
    (when (eq? (mblk-kind b) 'list-item) (mdata-set! b 'trailing-blank? (and below-quotes? line-blank?)))
    (or below-quotes? (eq? b deepest-quote)))
  (void))

(define (process-line-inner! doc source lr prefix-end)
  (define line-start (line-record-start lr))
  (define content-end (line-record-content-end lr))
  (define full-path (open-path-of doc))
  (define n (length full-path))
  (define tip (list-ref full-path (sub1 n)))
  (define tip-is-leaf? (memq (mblk-kind tip) '(paragraph code-block html-block)))
  (define containers
    (if tip-is-leaf? (take (cdr full-path) (- n 2)) (cdr full-path)))
  (define-values (k end-offset end-column blank-stop?)
    (match-containers containers source line-start content-end))
  (set-box! prefix-end end-offset)
  (define fully-matched? (= k (length containers)))
  (cond
    [fully-matched?
     (cond
       [tip-is-leaf? (continue-leaf! doc full-path tip source end-offset end-column content-end lr)]
       ;; A list whose last item has closed (an item that began with a blank line ends at the
       ;; second blank line) still accepts a new item of its own kind; anything else closes it
       ;; and opens under the list's parent -- never as a direct child of the list.
       [(eq? (mblk-kind tip) 'list)
        (unless (or (blank-from? source end-offset content-end)
                    (continues-list? tip source end-offset end-column content-end))
          (close-block! tip))
        (open-new-blocks! (list-ref full-path (- n 2)) source end-offset end-column content-end #f)]
       [else (open-new-blocks! (list-ref full-path k) source end-offset end-column content-end #f)])]
    [else
     ;; Not fully matched: try lazy continuation of a tip paragraph.
     (define lazy-candidate? (and tip-is-leaf? (eq? (mblk-kind tip) 'paragraph) (mblk-open? tip)))
     (define rest-blank? (blank-from? source end-offset content-end))
     ;; ANY list marker at the point of mismatch (matching the dangling list's own delimiter or
     ;; not) always closes the tip paragraph, either to extend that list with a new sibling item
     ;; or -- a different delimiter, e.g. "1. foo\n2. bar\n3) baz" -- to close it and start a new
     ;; one. The "can't interrupt with a blank first line / ordered must start at 1" restrictions
     ;; (checked generically below) exist only to keep a bare marker from starting a brand-new
     ;; list inside running prose that was never list content to begin with (spec, "List items";
     ;; contrast "foo\n*\n" with "- foo\n-\n- bar\n" and "1. foo\n2. bar\n3) baz\n").
     (define dangling-list
       (and (< k (length containers)) (eq? (mblk-kind (list-ref containers k)) 'list-item)
            (list-ref full-path k)))
     (define dangling-list-marker
       (and dangling-list (not rest-blank?)
            (try-list-marker source end-offset end-column content-end)))
     (define interrupt
       (and lazy-candidate? (not rest-blank?)
            (or dangling-list-marker
                (find-new-block-start source end-offset end-column content-end #t))))
     (cond
       [(and lazy-candidate? (not rest-blank?) (not interrupt))
        (define-values (src-start vindent) (paragraph-line-start source end-offset end-column content-end))
        (add-line! tip src-start content-end vindent)
        (touch-path! full-path content-end)]
       [else
        (for ([b (in-list (list-tail full-path (add1 k)))]) (close-block! b))
        ;; If the container that failed to match was a list-item, its enclosing 'list (at
        ;; full-path[k]) is left open rather than closed here: a fresh matching marker on this
        ;; line should extend that SAME list (open-new-blocks!'s compatibility check, below, does
        ;; this via append-child!), not create a new sibling list next to it.
        (define attach-index
          (if (and (< k (length containers)) (eq? (mblk-kind (list-ref containers k)) 'list-item))
              (sub1 k)
              k))
        ;; When extending a dangling list, open-new-blocks! must not re-apply the blank-first/
        ;; ordered-start-1 exclusions either (they exist to keep a bare marker from starting a
        ;; brand-new list inside running prose, not to stop one from continuing itself).
        (open-new-blocks! (list-ref full-path attach-index) source end-offset end-column content-end
                           (and lazy-candidate? (not rest-blank?) (not dangling-list-marker)))])]))

;; Would a line starting at (offset, column) add an item to list `lst`? A marker of the list's
;; kind and delimiter that is not a thematic break (which outranks list items).
(define (continues-list? lst source offset column content-end)
  (define d (try-list-marker source offset column content-end))
  (and d
       (not (try-thematic-break source offset column content-end))
       (eq? (mdata-ref lst 'ordered?) (eq? (car d) 'ordered))
       (eqv? (mdata-ref lst 'delimiter) (cadr d))))

;; Continues an already-open leaf block (code-block, html-block, or paragraph).
(define (continue-leaf! doc full-path leaf source offset column content-end lr)
  (case (mblk-kind leaf)
    [(code-block)
     (cond
       [(mdata-ref leaf 'fenced?)
        (define fc (mdata-ref leaf 'fence-char)) (define flen (mdata-ref leaf 'fence-length))
        (cond
          [(fence-closes? source offset column content-end fc flen)
           (add-fence-tokens! leaf source offset column content-end)
           (close-block! leaf) (touch-path! full-path content-end)]
          [else
           (define indent (mdata-ref leaf 'fence-indent))
           (define-values (o3 c3) (strip-up-to source offset column content-end indent))
           (define-values (src-start vindent) (leaf-line-start source o3 c3 content-end))
           (add-line! leaf src-start content-end vindent)
           (touch-path! full-path content-end)])]
       [else ; indented code
        (define-values (ns nc) (scan-indent source offset column content-end))
        (define avail (- nc column))
        (cond
          ;; A blank line continues too (any amount of whitespace, even none); either way, up to
          ;; 4 columns are stripped and whatever whitespace remains beyond that becomes literal
          ;; content (spec, "Indented code blocks" example: 6 spaces of blank leaves 2 behind).
          [(or (blank-from? source offset content-end) (>= avail 4))
           (define-values (o2 c2 p2) (advance-columns source offset column (min 4 avail) content-end))
           (define-values (src-start vindent) (leaf-line-start source o2 c2 content-end))
           (add-line! leaf src-start content-end vindent)
           (touch-path! full-path content-end)]
          [else
           (close-block! leaf)
           (open-new-blocks! (parent-of doc leaf) source offset column content-end #f)])])]
    [(html-block)
     (define kind (mdata-ref leaf 'kind))
     (define blank? (blank-from? source offset content-end))
     (cond
       [(and (memv kind '(6 7)) blank?)
        (close-block! leaf)
        (open-new-blocks! (parent-of doc leaf) source offset column content-end #f)]
       [(memv kind '(1 2 3 4 5))
        (add-line! leaf offset content-end 0)
        (touch-path! full-path content-end)
        (when (html-block-end-met? source offset content-end kind) (close-block! leaf))]
       [else
        (add-line! leaf offset content-end 0)
        (touch-path! full-path content-end)])]
    [(paragraph)
     (define rest-blank? (blank-from? source offset content-end))
     (cond
       [rest-blank?
        (close-block! leaf)
        (open-new-blocks! (parent-of doc leaf) source offset column content-end #f)]
       ;; A setext underline needs paragraph text left after the leading reference
       ;; definitions are taken out (spec examples 215-216); otherwise the line is ordinary.
       [(and (try-setext source offset column content-end)
             (not (only-link-ref-defs? source (leaf-lines leaf)))
             (try-setext source offset column content-end))
        => (lambda (level)
             (set-mblk-kind-heading! leaf level)
             (let*-values ([(ns nc) (scan-indent source offset column content-end)]
                           [(c) (string-ref source ns)])
               (add-token! leaf 'setext-underline ns
                           (let run ([i ns]) (if (and (< i content-end) (eqv? (string-ref source i) c)) (run (add1 i)) i))))
             (touch-path! full-path content-end)
             (close-block! leaf))]
       [(find-new-block-start source offset column content-end #t)
        (close-block! leaf)
        (open-new-blocks! (parent-of doc leaf) source offset column content-end #t)]
       [else
        (define-values (src-start vindent) (paragraph-line-start source offset column content-end))
        (add-line! leaf src-start content-end vindent)
        (touch-path! full-path content-end)])]))

;; Strips up to `n` columns of leading indentation from (offset,column), returning the position
;; reached (used for fenced-code content, which strips min(fence-indent, available) columns).
(define (strip-up-to source offset column content-end n)
  (define-values (ns nc) (scan-indent source offset column content-end))
  (define avail (- nc column))
  (define take (min n avail))
  (define-values (o2 c2 p2) (advance-columns source offset column take content-end))
  (values o2 c2))

(define (indent-available source offset column content-end)
  (define-values (ns nc) (scan-indent source offset column content-end))
  (- nc column))

;; Converts a still-open paragraph mblk in place into a setext heading (reusing its lines).
(define (set-mblk-kind-heading! b level)
  ;; mblk's kind field isn't mutable by design (immutable struct field would be simpler, but we
  ;; only ever need this one conversion); rebuild data with a 'heading? tag instead.
  (mdata-set! b 'setext-level level))

;; Finds the attachment point for whatever comes next after `leaf` was just closed: since `leaf`
;; is now closed, the freshly recomputed open path's tip *is* its (still-open) parent already.
(define (parent-of doc leaf) (last (open-path-of doc)))

;; Opens new blocks starting at (offset, column) under `parent`, looping to allow nested
;; container starts, then creating (at most) one leaf. `tip-was-paragraph?` marks that the
;; thing we're opening is interrupting a paragraph (affects which constructs are eligible).
;; Checked in the spec's order at every step: block quote, ATX heading, fenced code, HTML block,
;; thematic break (before list items, which it outranks), list item, indented code, paragraph.
(define (open-new-blocks! parent source offset column content-end tip-was-paragraph?)
  (let loop ([parent parent] [offset offset] [column column] [interrupt? tip-was-paragraph?])
    (cond
      [(blank-from? source offset content-end) (void)] ; nothing to open on a blank remainder
      [(match-blockquote-start? source offset column content-end)
       (define-values (marker o2 c2) (match-blockquote source offset column content-end))
       (define bq (make-mblk 'block-quote offset '()))
       (add-token! bq 'quote-marker marker (add1 marker))
       (append-child! parent bq)
       (loop bq o2 c2 #f)]
      [(try-atx source offset column content-end)
       => (lambda (d)
            (match-define (list level content-start) d)
            (define h (make-mblk 'heading offset (list (cons 'level level) (cons 'setext? #f))))
            (add-token! h 'heading-marker (- content-start level) content-start)
            (add-atx-content! h source content-start content-end)
            ;; Closed on the same line it opens: process-line!'s end-of-line touch-path! (which
            ;; only walks the *open* path) will never reach it, so its span is fixed up here.
            (set-mblk-end! h content-end)
            (close-block! h)
            (append-child! parent h))]
      [(try-fence-open source offset column content-end)
       => (lambda (d)
            (match-define (list fc flen findent info) d)
            (define cb (make-mblk 'code-block offset (list (cons 'fenced? #t) (cons 'fence-char fc)
                                                            (cons 'fence-length flen)
                                                            (cons 'fence-indent findent)
                                                            (cons 'info info))))
            (add-fence-tokens! cb source offset column content-end)
            (append-child! parent cb))]
      [(try-html-block-start source offset column content-end interrupt?)
       => (lambda (kind)
            (define hb (make-mblk 'html-block offset (list (cons 'kind kind))))
            (add-line! hb offset content-end 0)
            (set-mblk-end! hb content-end)
            (when (memv kind '(1 2 3 4 5))
              (when (html-block-end-met? source offset content-end kind) (close-block! hb)))
            (append-child! parent hb))]
      [(try-thematic-break source offset column content-end)
       (define tb (make-mblk 'thematic-break offset '()))
       (set-mblk-end! tb content-end)
       (close-block! tb)
       (append-child! parent tb)]
      [(try-list-marker source offset column content-end)
       => (lambda (d)
            (match-define (list kind delim start-number after after-col marker-col) d)
            (define-values (fns fnc) (scan-indent source after after-col content-end))
            (define blank-first? (>= fns content-end))
            (cond
              [(and interrupt? blank-first?) (open-paragraph-or-code! parent source offset column content-end interrupt?)]
              [(and interrupt? (eq? kind 'ordered) (not (equal? start-number 1)))
               (open-paragraph-or-code! parent source offset column content-end interrupt?)]
              [else
               (define content-column (list-content-column source after after-col content-end))
               (define item (make-mblk 'list-item offset (list (cons 'content-column content-column)
                                                                (cons 'marker-end after)
                                                                (cons 'blank-start? blank-first?))))
               ;; A marker holds no tabs, so its width in columns is its width in characters.
               (add-token! item (if (eq? kind 'bullet) 'bullet 'ordered-marker)
                           (- after (- after-col marker-col)) after)
               (define existing (let ([kids (mblk-children parent)])
                                   (and (pair? kids) (eq? (mblk-kind (car kids)) 'list) (mblk-open? (car kids))
                                        (car kids))))
               (define compatible?
                 (and existing (eq? (mdata-ref existing 'ordered?) (eq? kind 'ordered))
                      (eqv? (mdata-ref existing 'delimiter) delim)))
               (define lst
                 (if compatible?
                     existing
                     (let ([l (make-mblk 'list offset (list (cons 'ordered? (eq? kind 'ordered))
                                                             (cons 'start-number (or start-number 1))
                                                             (cons 'delimiter delim)))])
                       (append-child! parent l)
                       l)))
               (append-child! lst item)
               ;; Position the cursor for this item's own first line: consume exactly the
               ;; columns between the marker's end and its content-column (same computation
               ;; a continuation line would use), from the known post-marker position -- not
               ;; by re-matching the line from its very start, which would see the marker
               ;; character itself and fail.
               (define-values (o2 c2 p2) (advance-columns source after after-col (max 0 (- content-column after-col)) content-end))
               (loop item o2 c2 #f)]))]
      [else (open-paragraph-or-code! parent source offset column content-end interrupt?)])))

;; The last two candidates, checked in order: indented code (only when not interrupting a
;; paragraph), else a fresh (or continued) paragraph.
(define (open-paragraph-or-code! parent source offset column content-end interrupt?)
  (cond
    [(and (not interrupt?)
          (let-values ([(ns nc) (scan-indent source offset column content-end)])
            (>= (- nc column) 4)))
     (define cb (make-mblk 'code-block offset (list (cons 'fenced? #f))))
     (define-values (o2 c2 p2) (advance-columns source offset column 4 content-end))
     (define-values (src-start vindent) (leaf-line-start source o2 c2 content-end))
     (add-line! cb src-start content-end vindent)
     (append-child! parent cb)]
    [(blank-from? source offset content-end) (void)]
    [else
     (define-values (src-start vindent) (paragraph-line-start source offset column content-end))
     (define p (make-mblk 'paragraph offset '()))
     (add-line! p src-start content-end vindent)
     (append-child! parent p)]))

;; The fence run of an opening or closing fence line, and an opening fence's info string.
(define (add-fence-tokens! cb source offset column content-end)
  (define-values (ns nc) (scan-indent source offset column content-end))
  (define c (string-ref source ns))
  (define run-end (let run ([i ns]) (if (and (< i content-end) (eqv? (string-ref source i) c)) (run (add1 i)) i)))
  (add-token! cb 'fence ns run-end)
  (define-values (info-start _c) (scan-indent source run-end nc content-end))
  (define info-end (let back ([j content-end]) (if (and (> j info-start) (space-or-tab? (string-ref source (sub1 j)))) (back (sub1 j)) j)))
  (add-token! cb 'fence-info info-start info-end))

(define (add-atx-content! h source content-start content-end)
  ;; Trims leading whitespace, then a trailing closing sequence of '#'s (preceded by
  ;; whitespace or at the very start) and trailing whitespace.
  (define-values (ns nc) (values content-start 0))
  (let loop ([i content-start]) (if (and (< i content-end) (space-or-tab? (string-ref source i))) (loop (add1 i))
                                     (let ([start i])
                                       (define end
                                         (let trim ([j content-end])
                                           (if (and (> j start) (space-or-tab? (string-ref source (sub1 j))))
                                               (trim (sub1 j)) j)))
                                       (define end2
                                         (let closing ([j end] [count 0])
                                           (cond [(and (> j start) (eqv? (string-ref source (sub1 j)) #\#))
                                                  (closing (sub1 j) (add1 count))]
                                                 [(= count 0) end]
                                                 [(= j start) ; whole content was '#'s
                                                  (add-token! h 'heading-marker j end)
                                                  j]
                                                 [(space-or-tab? (string-ref source (sub1 j)))
                                                  (add-token! h 'heading-marker j end)
                                                  (let trim2 ([k (sub1 j)])
                                                    (if (and (> k start) (space-or-tab? (string-ref source (sub1 k))))
                                                        (trim2 (sub1 k)) k))]
                                                 [else end])))
                                       (add-line! h start end2 0)))))

;; ============================================================================================
;; Finalization: mutable tree -> immutable ast.rkt structs, refmap extraction, tight/loose.
;; ============================================================================================

;; The inline parser a leaf's cell will call: (kind content refmap) -> content-relative inline
;; list, kind being 'paragraph or 'heading. mdlib-parser passes one that consults its memo.
(define (default-inline-parser kind content refmap) (parse-inlines content refmap))
(define current-inline-parser (make-parameter default-inline-parser))

(define (leaf-cell kind segs content refmap)
  (define ip (current-inline-parser)) ; captured now: the cell is forced after parse-blocks returns
  (make-inline-cell content segs (lambda () (ip kind content refmap))))

(define (parse-blocks source #:extensions [extensions no-extensions]
                      #:inline-parser [inline-parser default-inline-parser])
  (define lines (source-lines source))
  (define line-idx (lines->line-index lines))
  (define doc (make-mblk 'document 0 '()))
  (for ([lr (in-list lines)]) (process-line! doc source lr))
  (close-all! doc)
  (touch-path! (list doc) (string-length source))
  (define refmap (make-hash))
  (define children
    (parameterize ([current-inline-parser inline-parser])
      (finalize-children source (reverse (mblk-children doc)) refmap)))
  (document 0 (string-length source) '() source children refmap line-idx extensions))

(define (close-all! b)
  (for ([c (in-list (mblk-children b))]) (when (mblk-open? c) (close-all! c) (close-block! c))))

(define (finalize-children source mchildren refmap)
  (append-map (lambda (b) (finalize-block source b refmap)) mchildren))

;; Returns a list of finalized immutable nodes for `b` -- usually one, '() if it disappears (a
;; paragraph that was entirely link reference definitions with no leftover text), or several
;; (one or more link-ref-def nodes, then a paragraph, when a paragraph starts with definitions
;; but has real content after them).
(define (finalize-block source b refmap)
  (case (mblk-kind b)
    [(document) '()] ; not reachable (only doc's children are finalized)
    [(block-quote)
     (list (block-quote (mblk-start b) (mblk-end b) (block-tokens-of b) (finalize-children source (reverse (mblk-children b)) refmap)))]
    [(list)
     (define kids (finalize-children source (reverse (mblk-children b)) refmap))
     (list (list-block (mblk-start b) (mblk-end b) '() (mdata-ref b 'ordered?) (mdata-ref b 'start-number)
                       (mdata-ref b 'delimiter) (list-tight? b) kids))]
    [(list-item)
     (define kids (finalize-children source (reverse (mblk-children b)) refmap))
     (list (list-item (mblk-start b) (mblk-end b) (block-tokens-of b) (mdata-ref b 'marker-end) (mdata-ref b 'content-column) #f kids))]
    [(thematic-break) (list (thematic-break (mblk-start b) (mblk-end b) '()))]
    [(code-block)
     (define lns (leaf-lines b))
     (define out-lines (for/list ([l (in-list lns)]) (list (first l) (+ (first l) (second l)) (third l))))
     (define fenced? (mdata-ref b 'fenced?))
     (list (code-block (mblk-start b) (mblk-end b) (block-tokens-of b) fenced?
                       (and fenced? (mdata-ref b 'fence-char))
                       (and fenced? (let ([i (mdata-ref b 'info)]) (if (equal? i "") #f i)))
                       (trim-trailing-blank-lines source out-lines fenced?)))]
    [(html-block)
     (define lns (leaf-lines b))
     (define out-lines (for/list ([l (in-list lns)]) (list (first l) (+ (first l) (second l)) (third l))))
     (list (html-block (mblk-start b) (mblk-end b) '() (mdata-ref b 'kind) out-lines))]
    [(heading)
     (define-values (segs content) (build-segments+content source (leaf-lines b)))
     (list (heading (mblk-start b) (mblk-end b) (block-tokens-of b) (mdata-ref b 'level) #f #f segs
                    (leaf-cell 'heading segs content refmap)))]
    [(paragraph)
     (cond
       [(mdata-ref b 'setext-level)
        => (lambda (level)
             (define-values (remaining refdefs) (strip-link-ref-defs source (leaf-lines b) refmap))
             (define-values (segs content)
               (build-segments+content source (trim-trailing-line-ws source remaining)))
             (append refdefs
                     (list (heading (if (null? refdefs) (mblk-start b) (first (car remaining)))
                                    (mblk-end b) (block-tokens-of b) level #t #f segs
                                    (leaf-cell 'heading segs content refmap)))))]
       [else
        (define-values (remaining refdefs) (strip-link-ref-defs source (leaf-lines b) refmap))
        (define para
          (and (pair? remaining)
               (let-values ([(segs content) (build-segments+content source (trim-trailing-line-ws source remaining))])
                 (and (for/or ([c (in-string content)]) (not (char-whitespace? c))) ; not string-trim: it costs ~25 ns/char
                      ;; Start after any stripped leading ref-defs, not at b's original start,
                      ;; so this span doesn't overlap the ref-def nodes' own spans.
                      (paragraph (first (car remaining)) (mblk-end b) '() segs
                                 (leaf-cell 'paragraph segs content refmap))))))
        (append refdefs (if para (list para) '()))])]
    [else '()]))

;; A code-block line is blank if its real (non-virtual) source slice is empty or all
;; whitespace -- note this is independent of its *stripped content's* length, which can be
;; non-zero when the line had more than 4 columns of indentation to begin with.
(define (code-line-blank? source l)
  (blank-string? (substring source (first l) (second l))))

(define (trim-trailing-blank-lines source out-lines fenced?)
  (if fenced?
      out-lines
      (reverse (let drop-trailing ([rl (reverse out-lines)])
                 (if (and (pair? rl) (code-line-blank? source (car rl)))
                     (drop-trailing (cdr rl))
                     rl)))))

;; Tight iff neither looseness flag append-child! records was ever set (spec, "Lists": loose iff
;; any two items are separated by a blank line, or an item directly contains two block-level
;; children separated by one).
(define (list-tight? lst)
  (not (or (mdata-ref lst 'loose?)
           (for/or ([item (in-list (mblk-children lst))]) (mdata-ref item 'internal-blank?)))))

;; --- Link reference definitions (design §2.1, §1.4) --------------------------------------------

;; Attempts to strip one or more leading reference definitions from a paragraph's raw lines.
;; Returns (values remaining-lines refdef-nodes): remaining-lines is what's left for the
;; paragraph (possibly '(), if the whole thing was reference definitions), and refdef-nodes is
;; the list of finalized link-ref-def structs (design §1.4: "kept in the tree so it can be
;; styled and edited"), each registered into `refmap` too (first definition for a label wins).
(define (strip-link-ref-defs source lines refmap)
  ;; The paragraph is joined once and definitions are read from successive offsets, keeping a
  ;; paragraph of 50,000 definitions linear (tests/pathological-test.rkt, "many references").
  (if (starts-with-bracket? source lines)
      (strip-link-ref-defs* source lines refmap)
      (values lines '())))

(define (strip-link-ref-defs* source lines refmap)
  (define text (line-join source lines))
  (define line-vec (list->vector lines))
  (define joined-starts ; where each line starts in `text`
    (for/fold ([acc '()] [pos 0] #:result (list->vector (reverse acc))) ([l (in-list lines)])
      (values (cons pos acc) (+ pos (second l) 1))))
  ;; A token over [a, b) of `text`, as source tokens, one per line it touches among the
  ;; definition's lines [from, to) (only those: a paragraph of 50,000 definitions stays linear).
  (define (source-tokens role a b from to)
    (for/list ([i (in-range from to)]
               #:when (let ([js (vector-ref joined-starts i)])
                        (< (max a js) (min b (+ js (second (vector-ref line-vec i)))))))
      (define l (vector-ref line-vec i)) (define js (vector-ref joined-starts i))
      (token role (+ (first l) (- (max a js) js)) (+ (first l) (- (min b (+ js (second l))) js)))))
  (let loop ([lines lines] [pos 0] [defs '()] [line-no 0])
    (cond
      [(null? lines) (values lines (reverse defs))]
      [else
       (match (parse-one-ref-def text pos)
         [(list label dest title consumed-lines next-pos (vector ls le ds de ts te))
          (define norm (normalize-label label))
          (cond
            [(non-empty-normalized? norm)
             (define used (take lines consumed-lines))
             (define def-start (first (car used)))
             (define def-end (let ([l (last used)]) (+ (first l) (second l))))
             (define to (+ line-no consumed-lines))
             (define tokens
               (append (source-tokens 'refdef-label ls le line-no to)
                       (source-tokens 'refdef-dest ds de line-no to)
                       (if te (source-tokens 'refdef-title ts te line-no to) '())))
             (define node (link-ref-def def-start def-end tokens label dest title))
             ;; Design §1.4: normalized label -> (dest title node); the first definition wins.
             (unless (hash-has-key? refmap norm)
               (hash-set! refmap norm (list dest title node)))
             (loop (list-tail lines consumed-lines) next-pos (cons node defs) to)]
            [else (values lines (reverse defs))])] ; invalid (empty) label: keep as paragraph text
         [#f (values lines (reverse defs))])])))

;; #t when a paragraph's lines are nothing but reference definitions (a scratch refmap is
;; used: registration happens at finalization, in document order).
(define (only-link-ref-defs? source lines)
  (define-values (remaining defs) (strip-link-ref-defs source lines (make-hash)))
  (null? remaining))

;; Every definition starts with `[` at the paragraph's first character: most paragraphs are
;; ruled out here without joining their lines.
(define (starts-with-bracket? source lines)
  (and (pair? lines)
       (let ([l (car lines)]) (and (> (cadr l) 0) (eqv? (string-ref source (car l)) #\[)))))

(define (non-empty-normalized? s) (> (string-length s) 0))

(define (line-join source lines)
  (string-join (for/list ([l (in-list lines)]) (substring source (first l) (+ (first l) (second l)))) "\n"))

;; A reader for "[label]: dest \"title\"" possibly spanning several of `lines`, following
;; commonmark.js's parseReference with the scanners shared with the inline phase (refs.rkt).
;; Reads the definition starting at offset `start` (a line start) of `joined`. Returns (list
;; label dest title lines-consumed next-line-start positions) or #f if no definition starts
;; there; positions is (vector label-start label-end dest-start dest-end title-start title-end),
;; offsets into `joined`, title-end #f without a title.
(define (parse-one-ref-def joined start)
  (define len (string-length joined))
  (let/ec return
    (define (fail) (return #f))
    (unless (and (< start len) (eqv? (string-ref joined start) #\[)) (fail))
    (define label-end (scan-link-label joined start len)) ; just after `]`
    (unless label-end (fail))
    (unless (and (< label-end len) (eqv? (string-ref joined label-end) #\:)) (fail))
    (define label (substring joined (add1 start) (sub1 label-end)))
    (define dest-start (skip-spnl joined (add1 label-end) len))
    (define-values (dest after-dest) (scan-link-destination joined dest-start len #:allow-empty? #f))
    (unless dest (fail))
    (define title-start (skip-spnl joined after-dest len))
    (define-values (title after-title)
      (if (> title-start after-dest)
          (scan-link-title joined title-start len)
          (values #f after-dest)))
    (define (finish title end)
      (define nl (line-end-at joined end))
      (list label dest title (add1 (count-newlines joined start end)) (min len (add1 nl))
            (vector start label-end dest-start after-dest title-start (and title after-title))))
    (cond
      [(and title (rest-of-line-blank? joined after-title)) (finish title after-title)]
      [(rest-of-line-blank? joined after-dest) (finish #f after-dest)]
      [else (fail)])))

(define (line-end-at s pos)
  (or (for/first ([i (in-range pos (string-length s))] #:when (eqv? (string-ref s i) #\newline)) i)
      (string-length s)))

(define (rest-of-line-blank? s pos)
  (blank-string? (substring s pos (line-end-at s pos))))

(define (count-newlines s from to)
  (for/sum ([i (in-range from (min to (string-length s)))] #:when (eqv? (string-ref s i) #\newline)) 1))
