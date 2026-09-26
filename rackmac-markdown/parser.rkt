#lang racket/base
;; The parser object (design §3.1): one per open document. It runs the block phase in full on
;; every (re)parse and memoizes the inline phase per leaf block, so a keystroke costs the block
;; pass plus one leaf's inline parse. `parser-reparse!` also returns a `change-report` saying
;; which characters of the new document may be styled differently from the old document's
;; characters they came from: what `md-restyle-region` (#266) restyles.
;;
;; The inline memo. A leaf's content-relative inline tree is a function of (leaf kind, content
;; string, refmap, extension set + keyword snapshot) and nothing else, so that tuple is the key.
;; The refmap enters as a fingerprint: the sorted (label dest title) triples, without the
;; definition nodes, whose positions move on every edit. Rather than hashing that list (a hash
;; collision would silently break `reparse == parse`), each distinct list gets a generation
;; number, and the table is stamped with (generation, extension set): a table whose stamp differs
;; from the new parse's is dropped, which is the same as keying each entry by the full tuple.
;; Hashing every leaf's content on every keystroke would cost as much as the block pass itself
;; (300 KB of strings, twice), so the table is consulted only for leaves the change report finds
;; changed; a leaf that matched an old leaf under the edit's shift (same kind, same content)
;; takes the old leaf's tree directly, by identity of its content string. Misses stay lazy (the
;; Source view never forces them, design §3.2) and enter the table when forced. The table keeps
;; living across parses and is rebuilt from the current document's leaves when it grows past
;; twice their number, so memory stays proportional to the document.
;;
;; The change report. "This leaf missed the memo" is not the same as "this leaf's styling
;; changed": typing in one paragraph until its content equals another's is a memo hit whose
;; styling changed. So the report comes from comparing the old tree with the new under the
;; edit's offset map (before the edit: unchanged; after it: shifted by the size delta; inside the
;; replaced text: unmatchable). Two blocks match when every range in them maps with one shift and
;; all other fields are equal; leaf inline trees are compared through their content string and
;; segments (never `equal?`, which would force the inline phase), which is exact given the
;; memo's own reasoning. Children lists are compared by common prefix and suffix; a middle of one
;; old and one new container with equal headers is compared recursively (the list holding the
;; edited paragraph changes its end, not its styling), and container tokens (`>`, bullets) are
;; diffed the same way.
(require racket/list racket/promise
         "ast.rkt" "blocks.rkt" "inlines.rkt")
(provide make-parser parser? parser-extensions parser-document
         parser-parse! parser-reparse!
         (struct-out change-report)
         leaf-blocks)

;; ranges: sorted, disjoint, non-adjacent (start . end) pairs in the new document's offsets:
;;   restyle these characters. Always includes the inserted text.
;; blocks: the new document's blocks that differ from the old document's (outermost ones, in
;;   order): their paragraph layout (margins, kind, depth, marker) must be re-applied.
;; inline-changed: the new leaf blocks (paragraphs, headings) whose inline tree is not the old
;;   one shifted; every one lies inside `ranges` unless `refmap-changed?`, when it is every leaf.
;; structure-changed?: the block sequence changed (a block split, joined, converted, added or
;;   removed, a container marker or header changed); #f when the edit stayed inside leaves.
;; refmap-changed?: the reference definitions changed, so every leaf's inlines were re-parsed.
(struct change-report (ranges blocks inline-changed structure-changed? refmap-changed?)
  #:transparent)

(struct parser (extensions
                heading-keywords           ; keyword lists snapshotted at make-parser (design §3.1)
                date-keywords
                [document #:mutable]       ; the last parse's document, or #f
                [refdefs #:mutable]        ; sorted (label dest title) list of that parse
                [generation #:mutable]     ; its refmap fingerprint
                [memo #:mutable]           ; (kind . content) -> content-relative inline list
                [memo-stamp #:mutable]     ; (list generation extensions keywords...) the memo was built for
                [memo-limit #:mutable]))   ; size past which the memo is checked for rebuilding

(define (make-parser #:extensions [extensions no-extensions])
  (parser extensions (heading-keywords) (date-keywords) #f #f 0 (make-hash) #f 64))

(define (parser-parse! p text)
  (define-values (doc report) (run-parse! p text #f))
  doc)

(define (parser-reparse! p text e)
  (define old (parser-document p))
  (when old
    (define old-len (string-length (document-text old)))
    (define es (edit-start e)) (define ee (edit-end e))
    (unless (and (<= 0 es ee old-len)
                 (= (string-length text) (+ old-len (- (string-length (edit-text e)) (- ee es)))))
      (raise-arguments-error 'parser-reparse! "the edit does not turn the last parsed text into the new text"
                             "edit" e "old length" old-len "new length" (string-length text))))
  (run-parse! p text e))

;; ---------------------------------------------------------------------------------------------
;; Parsing through the memo
;; ---------------------------------------------------------------------------------------------

;; Parses `text`; with an edit `e` and a previous document, also diffs the two. Returns the
;; document and the change report (#f without an edit).
(define (run-parse! p text e)
  (define old (parser-document p))
  (define reuse (make-hasheq)) ; content string (by identity) -> the matched old leaf's tree
  (define table #f)            ; set below, before any cell can be forced
  (define (memo-inline-parser kind content refmap)
    (define reused (hash-ref reuse content none))
    (cond
      [(not (eq? reused none)) reused]
      [else
       (define key (cons kind content))
       (define hit (hash-ref table key none))
       (cond
         [(eq? hit none)
          (define r (parse-inlines content refmap
                                   (inline-options (parser-extensions p) kind
                                                   (parser-heading-keywords p) (parser-date-keywords p))))
          (hash-set! table key r)
          r]
         [else hit])]))
  (define doc (parse-blocks text #:extensions (parser-extensions p) #:inline-parser memo-inline-parser
                           #:heading-keywords (parser-heading-keywords p)
                           #:date-keywords (parser-date-keywords p)))
  (define refdefs (refmap->refdefs (document-refmap doc)))
  (define refmap-changed? (not (and old (equal? refdefs (parser-refdefs p)))))
  (define generation (if refmap-changed? (add1 (parser-generation p)) (parser-generation p)))
  (define stamp (list generation (parser-extensions p) (parser-heading-keywords p) (parser-date-keywords p)))
  (define same-stamp? (equal? stamp (parser-memo-stamp p)))
  (set! table (if same-stamp? (parser-memo p) (make-hash)))
  (define report
    (and e
         (if old
             (let-values ([(report matched) (diff-documents old doc e refmap-changed?)])
               (when same-stamp?
                 (for ([m (in-list matched)])
                   (define rel (inline-cell-relative (leaf-cell (car m))))
                   (when (promise-forced? rel)
                     (hash-set! reuse (inline-cell-content (leaf-cell (cdr m))) (force rel)))))
               report)
             (full-report doc))))
  (when (> (hash-count table) (parser-memo-limit p))
    (define limit (+ 64 (* 2 (length (leaf-blocks doc)))))
    (when (> (hash-count table) limit) (set! table (rebuild-table doc)))
    (set-parser-memo-limit! p (max limit (+ 64 (hash-count table)))))
  (set-parser-document! p doc)
  (set-parser-refdefs! p refdefs)
  (set-parser-generation! p generation)
  (set-parser-memo! p table)
  (set-parser-memo-stamp! p stamp)
  (values doc report))

;; A table holding only the given document's leaves whose trees are known (forced): the others
;; will enter it when forced.
(define (rebuild-table doc)
  (define t (make-hash))
  (for ([b (in-list (leaf-blocks doc))])
    (define rel (inline-cell-relative (leaf-cell b)))
    (when (promise-forced? rel)
      (hash-set! t (cons (leaf-kind b) (inline-cell-content (leaf-cell b))) (force rel))))
  t)

(define none (string->uninterned-symbol "none"))

(define (refmap->refdefs refmap)
  (sort (for/list ([(label v) (in-hash refmap)]) (list label (car v) (cadr v)))
        string<? #:key car))

(define (leaf-kind b) (cond [(heading? b) 'heading] [(table-cell? b) 'table-cell] [else 'paragraph]))
(define (leaf-cell b)
  (cond [(heading? b) (heading-inlines b)] [(table-cell? b) (table-cell-inlines b)] [else (paragraph-inlines b)]))

(define (block-kids b)
  (cond
    [(document? b) (document-children b)]
    [(block-quote? b) (block-quote-children b)]
    [(list-block? b) (list-block-children b)]
    [(list-item? b) (list-item-children b)]
    [(table? b) (append (table-head b) (apply append (table-rows b)))]
    [else '()]))

;; The blocks with inline content (paragraphs, headings, table cells) of `b` (a document or any
;; block), in document order.
(define (leaf-blocks b)
  (let loop ([b b] [acc '()])
    (cond
      [(or (paragraph? b) (heading? b) (table-cell? b)) (cons b acc)]
      [else (for/fold ([acc acc]) ([k (in-list (reverse (block-kids b)))]) (loop k acc))])))

;; ---------------------------------------------------------------------------------------------
;; The change report
;; ---------------------------------------------------------------------------------------------

(define (full-report doc)
  (define len (string-length (document-text doc)))
  (change-report (if (> len 0) (list (cons 0 len)) '()) (document-children doc) (leaf-blocks doc) #t #t))

(define (diff-documents old new e refmap-changed?)
  (define es (edit-start e)) (define ee (edit-end e))
  (define inserted (string-length (edit-text e)))
  (define delta (- inserted (- ee es)))
  ;; The shift a range [a, b) of the old text moves by, or #f if the edit touches its inside.
  ;; A range ending at the edit start stays; one starting at the edit end moves (for an
  ;; insertion, an empty range at the insertion point stays).
  (define (range-shift a b)
    (cond [(<= b es) 0]
          [(>= a ee) delta]
          [else #f]))
  ;; A single old position, or #f inside the replaced text.
  (define (point-map q) (cond [(< q es) q] [(>= q ee) (+ q delta)] [else #f]))
  ;; An old range's image, clamped into the inserted text where it overlaps the edit.
  (define (clamp-start q) (cond [(< q es) q] [(>= q ee) (+ q delta)] [else es]))
  (define (clamp-end q) (cond [(<= q es) q] [(>= q ee) (+ q delta)] [else (+ es inserted)]))

  (define ranges '())       ; (start . end), unordered
  (define matched '())      ; (old-leaf . new-leaf): paragraphs and headings with equal content
  (define changed '())      ; new blocks, reverse order
  (define structure? #f)
  (define (add-range! s e) (when (< s e) (set! ranges (cons (cons s e) ranges))))

  ;; --- equality under a known shift d ---
  (define (tokens-eq? xs ys d)
    (cond [(null? xs) (null? ys)]
          [(null? ys) #f]
          [else (let ([x (car xs)] [y (car ys)])
                  (and (eq? (token-role x) (token-role y))
                       (= (+ (token-start x) d) (token-start y))
                       (= (+ (token-end x) d) (token-end y))
                       (tokens-eq? (cdr xs) (cdr ys) d)))]))
  (define (segments-eq? xs ys d)
    (cond [(null? xs) (null? ys)]
          [(null? ys) #f]
          [else (let ([x (car xs)] [y (car ys)])
                  (and (= (segment-content-start x) (segment-content-start y))
                       (= (segment-content-length x) (segment-content-length y))
                       (= (+ (segment-source-start x) d) (segment-source-start y))
                       (= (segment-source-length x) (segment-source-length y))
                       ;; the source text behind the segment lies outside the edit, so it
                       ;; is the same text (see cells-eq?)
                       (or (= 0 (segment-source-length x))
                           (eqv? d (range-shift (segment-source-start x)
                                                (+ (segment-source-start x) (segment-source-length x)))))
                       (segments-eq? (cdr xs) (cdr ys) d)))]))
  (define (lines-eq? xs ys d) ; code and HTML block lines: (start end virtual-indent)
    (cond [(null? xs) (null? ys)]
          [(null? ys) #f]
          [else (let ([x (car xs)] [y (car ys)])
                  (and (= (+ (car x) d) (car y)) (= (+ (cadr x) d) (cadr y)) (= (caddr x) (caddr y))
                       (lines-eq? (cdr xs) (cdr ys) d)))]))
;; A leaf's content is its segments' source text (virtual spaces for zero-length ones) joined
  ;; by newlines, so segments equal under the shift, over source text the edit did not touch,
  ;; mean equal content: comparing the strings too would cost half the diff.
  (define (cells-eq? a b)
    (= (string-length (inline-cell-content a)) (string-length (inline-cell-content b))))
  ;; Records a pair of leaves of the same kind with equal content: whatever else the comparison
  ;; finds, their content-relative inline trees are the same (design §3.1).
  (define (match! o n) (set! matched (cons (cons o n) matched)) #t)
  (define (kids-eq? xs ys d)
    (cond [(null? xs) (null? ys)]
          [(null? ys) #f]
          [else (and (block-eq? (car xs) (car ys) d) (kids-eq? (cdr xs) (cdr ys) d))]))
  (define (block-eq? o n d)
    (and (= (+ (block-start o) d) (block-start n))
         (= (+ (block-end o) d) (block-end n))
         (tokens-eq? (block-tokens o) (block-tokens n) d)
         (cond
           [(paragraph? o)
            (and (paragraph? n)
                 (segments-eq? (paragraph-segments o) (paragraph-segments n) d)
                 (cells-eq? (paragraph-inlines o) (paragraph-inlines n))
                 (match! o n))]
           [(heading? o)
            (and (heading? n)
                 (= (heading-level o) (heading-level n))
                 (eq? (heading-setext? o) (heading-setext? n))
                 (equal? (heading-keyword o) (heading-keyword n))
                 (segments-eq? (heading-segments o) (heading-segments n) d)
                 (cells-eq? (heading-inlines o) (heading-inlines n))
                 (match! o n))]
           [(thematic-break? o) (thematic-break? n)]
           [(code-block? o)
            (and (code-block? n)
                 (eq? (code-block-fenced? o) (code-block-fenced? n))
                 (eqv? (code-block-fence-char o) (code-block-fence-char n))
                 (equal? (code-block-info o) (code-block-info n))
                 (lines-eq? (code-block-lines o) (code-block-lines n) d))]
           [(html-block? o)
            (and (html-block? n)
                 (eqv? (html-block-kind o) (html-block-kind n))
                 (lines-eq? (html-block-lines o) (html-block-lines n) d))]
           [(table-cell? o)
            (and (table-cell? n)
                 (segments-eq? (table-cell-segments o) (table-cell-segments n) d)
                 (cells-eq? (table-cell-inlines o) (table-cell-inlines n))
                 (match! o n))]
           [(table? o)
            (and (table? n)
                 (equal? (table-alignments o) (table-alignments n))
                 (kids-eq? (table-head o) (table-head n) d)
                 (= (length (table-rows o)) (length (table-rows n)))
                 (for/and ([ro (in-list (table-rows o))] [rn (in-list (table-rows n))]) (kids-eq? ro rn d)))]
           [(front-matter? o) (and (front-matter? n) (equal? (front-matter-fields o) (front-matter-fields n)))]
           [(link-ref-def? o)
            (and (link-ref-def? n)
                 (equal? (link-ref-def-label o) (link-ref-def-label n))
                 (equal? (link-ref-def-dest o) (link-ref-def-dest n))
                 (equal? (link-ref-def-title o) (link-ref-def-title n)))]
           [(block-quote? o)
            (and (block-quote? n) (kids-eq? (block-quote-children o) (block-quote-children n) d))]
           [(list-block? o)
            (and (list-block? n) (list-headers-eq? o n)
                 (kids-eq? (list-block-children o) (list-block-children n) d))]
           [(list-item? o)
            (and (list-item? n)
                 (= (+ (list-item-marker-end o) d) (list-item-marker-end n))
                 (item-headers-eq? o n)
                 (kids-eq? (list-item-children o) (list-item-children n) d))]
           [else #f])))
  (define (list-headers-eq? o n)
    (and (eq? (list-block-ordered? o) (list-block-ordered? n))
         (eqv? (list-block-start-number o) (list-block-start-number n))
         (eqv? (list-block-delimiter o) (list-block-delimiter n))
         (eq? (list-block-tight? o) (list-block-tight? n))))
  (define (item-headers-eq? o n)
    (and (eqv? (list-item-content-indent o) (list-item-content-indent n))
         (eq? (list-item-task o) (list-item-task n))))
  ;; Blocks the edit leaves alone, compared under the shift their span implies.
  (define (block-same? o n)
    (define d (range-shift (block-start o) (block-end o)))
    (and d (block-eq? o n d)))
  ;; Containers holding the edit: same kind and header, start not inside the replaced text.
  (define (container-header-same? o n)
    (and (let ([s (point-map (block-start o))]) (and s (= s (block-start n))))
         (cond
           [(block-quote? o) (block-quote? n)]
           [(list-block? o) (and (list-block? n) (list-headers-eq? o n))]
           [(list-item? o)
            (and (list-item? n)
                 (let ([m (point-map (list-item-marker-end o))]) (and m (= m (list-item-marker-end n))))
                 (item-headers-eq? o n)
                 ;; an empty item is a paragraph of its own for layout (runs.rkt)
                 (eq? (null? (list-item-children o)) (null? (list-item-children n))))]
           [else #f])))

  ;; --- sequence diff: common prefix, common suffix, and what is left between them ---
  (define (diff-seq! ov nv same?)
    (define lo (vector-length ov)) (define ln (vector-length nv))
    (define i (let loop ([i 0]) (if (and (< i lo) (< i ln) (same? (vector-ref ov i) (vector-ref nv i))) (loop (add1 i)) i)))
    (define j (let loop ([j 0])
                (if (and (< (+ i j) lo) (< (+ i j) ln)
                         (same? (vector-ref ov (- lo j 1)) (vector-ref nv (- ln j 1))))
                    (loop (add1 j))
                    j)))
    (values i (- lo j) i (- ln j)))

  (define (diff-children! okids nkids)
    (define ov (list->vector okids)) (define nv (list->vector nkids))
    (define-values (o0 o1 n0 n1) (diff-seq! ov nv block-same?))
    (cond
      [(and (= (- o1 o0) 1) (= (- n1 n0) 1)
            (container-header-same? (vector-ref ov o0) (vector-ref nv n0)))
       (define o (vector-ref ov o0)) (define n (vector-ref nv n0))
       ;; characters entering or leaving the container's span (a quote's role covers it all)
       (let ([oe (clamp-end (block-end o))] [ne (block-end n)])
         (add-range! (min oe ne) (max oe ne)))
       (diff-tokens! (block-tokens o) (block-tokens n))
       (diff-children! (block-kids o) (block-kids n))]
      [(or (< o0 o1) (< n0 n1))
       (unless (and (= (- o1 o0) 1) (= (- n1 n0) 1)
                    (same-leaf-shape? (vector-ref ov o0) (vector-ref nv n0)))
         (set! structure? #t))
       (when (< n0 n1)
         (add-range! (block-start (vector-ref nv n0)) (block-end (vector-ref nv (sub1 n1))))
         (for ([k (in-range n0 n1)]) (set! changed (cons (vector-ref nv k) changed))))
       (when (< o0 o1)
         (add-range! (clamp-start (block-start (vector-ref ov o0)))
                     (clamp-end (block-end (vector-ref ov (sub1 o1))))))]
      [else (void)]))

  (define (diff-tokens! otoks ntoks)
    (define ov (list->vector otoks)) (define nv (list->vector ntoks))
    (define-values (o0 o1 n0 n1)
      (diff-seq! ov nv (lambda (x y)
                         (define d (range-shift (token-start x) (token-end x)))
                         (and d (eq? (token-role x) (token-role y))
                              (= (+ (token-start x) d) (token-start y))
                              (= (+ (token-end x) d) (token-end y))))))
    (when (or (< o0 o1) (< n0 n1))
      (set! structure? #t)
      (when (< n0 n1) (add-range! (token-start (vector-ref nv n0)) (token-end (vector-ref nv (sub1 n1)))))
      (when (< o0 o1) (add-range! (clamp-start (token-start (vector-ref ov o0)))
                                  (clamp-end (token-end (vector-ref ov (sub1 o1))))))))

  (diff-children! (document-children old) (document-children new))
  (add-range! es (+ es inserted))
  (define merged (merge-ranges ranges))
  (define changed-blocks (reverse changed))
  (values (change-report merged
                         changed-blocks
                         (if refmap-changed?
                             (leaf-blocks new)
                             (append-map leaf-blocks changed-blocks))
                         structure?
                         refmap-changed?)
          matched))

;; One leaf replaced by one leaf of the same kind (and heading level): an edit inside a block.
(define (same-leaf-shape? o n)
  (or (and (paragraph? o) (paragraph? n))
      (and (heading? o) (heading? n) (= (heading-level o) (heading-level n))
           (eq? (heading-setext? o) (heading-setext? n)))
      (and (code-block? o) (code-block? n) (eq? (code-block-fenced? o) (code-block-fenced? n)))
      (and (html-block? o) (html-block? n))
      (and (link-ref-def? o) (link-ref-def? n))
      (and (table? o) (table? n) (equal? (table-alignments o) (table-alignments n)))
      (and (front-matter? o) (front-matter? n))))

(define (merge-ranges rs)
  (let loop ([rs (sort rs < #:key car)] [acc '()])
    (cond
      [(null? rs) (reverse acc)]
      [(and (pair? acc) (<= (car (car rs)) (cdr (car acc))))
       (loop (cdr rs) (cons (cons (car (car acc)) (max (cdr (car acc)) (cdr (car rs)))) (cdr acc)))]
      [else (loop (cdr rs) (cons (car rs) acc))])))
