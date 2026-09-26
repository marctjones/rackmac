#lang racket/base
;; Token-based edit operations (design §4.4, mdlib-edits #323): the formatting commands
;; (`md-format-commands`), list behavior (`md-lists-enter`) and the task toggle compute text
;; edits from the parse tree's tokens instead of re-serializing, so each diff touches only the
;; delimiters, markers and line prefixes it names, and undo stays natural.
;;
;; Every operation takes a parsed document and positions in its text and returns `edit`s
;; (ast.rkt: replace [start, end) of the OLD text by `text`), sorted by start and pairwise
;; non-overlapping (two edits may touch). A consumer applies them last to first, inside one
;; undoable edit sequence, so earlier offsets stay valid; `apply-edits` does the same to a
;; string and `map-position` carries a position of the old text into the new one.
;;
;; The operations:
;;   toggle-emphasis-edits  strong/emph/strike/code on a selection or the word at the caret
;;   set-heading-level-edits  heading level 1-6, or 0 for body text, on the lines of a selection
;;   toggle-list-edits      bulleted/numbered/checklist on the lines of a selection
;;   toggle-quote-edits     block quote on the lines of a selection
;;   list-enter-edits       Enter in a list item: continue the list, or end it on an empty item
;;   indent-list-edits / outdent-list-edits   move list items one level in or out
;;   toggle-task-edits / set-task-edits       the [ ] [x] [-] marker of a task item
(require racket/list racket/string "ast.rkt" "inlines.rkt")
(provide apply-edits map-position
         toggle-emphasis-edits set-heading-level-edits
         toggle-list-edits toggle-quote-edits
         list-enter-edits indent-list-edits outdent-list-edits
         toggle-task-edits set-task-edits)

;; ============================================================================================
;; Edits
;; ============================================================================================

;; Sorted by (start, end) (stable, so insertions at one point keep their order and merge),
;; with no-ops dropped. Overlap would be a bug in an operation: it raises.
(define (normalize-edits text es)
  (define sorted
    (sort (filter (lambda (e) (not (equal? (substring text (edit-start e) (edit-end e)) (edit-text e)))) es)
          (lambda (a b) (or (< (edit-start a) (edit-start b))
                            (and (= (edit-start a) (edit-start b)) (< (edit-end a) (edit-end b)))))))
  (define merged
    (let loop ([es sorted] [acc '()])
      (cond
        [(null? es) (reverse acc)]
        [(and (pair? acc)
              (let ([a (car acc)] [b (car es)])
                (= (edit-start a) (edit-end a) (edit-start b) (edit-end b))))
         (loop (cdr es) (cons (edit (edit-start (car acc)) (edit-end (car acc))
                                    (string-append (edit-text (car acc)) (edit-text (car es))))
                              (cdr acc)))]
        [else (loop (cdr es) (cons (car es) acc))])))
  (for ([a (in-list merged)] [b (in-list (if (null? merged) '() (cdr merged)))])
    (when (> (edit-end a) (edit-start b))
      (error 'rackmac-markdown "internal error: overlapping edits ~a ~a" a b)))
  merged)

;; The new text: `edits` sorted and non-overlapping, offsets into `text`.
(define (apply-edits text edits)
  (define out (open-output-string))
  (let loop ([pos 0] [es edits])
    (cond
      [(null? es) (write-string text out pos)]
      [else
       (define e (car es))
       (write-string text out pos (edit-start e))
       (write-string (edit-text e) out)
       (loop (edit-end e) (cdr es))]))
  (get-output-string out))

;; Where position `pos` of the old text lands in the new one. An insertion exactly at `pos`, or
;; a replacement of a range holding `pos`, puts it after the new text with bias 'after and
;; before it with 'before.
(define (map-position edits pos [bias 'after])
  (let loop ([es edits] [delta 0])
    (cond
      [(null? es) (+ pos delta)]
      [else
       (define e (car es))
       (define s (edit-start e)) (define en (edit-end e)) (define n (string-length (edit-text e)))
       (cond
         [(< pos s) (+ pos delta)]
         [(or (> pos en) (and (= pos en) (< s en))) (loop (cdr es) (+ delta (- n (- en s))))]
         [else (+ s delta (if (eq? bias 'after) n 0))])])))

;; ============================================================================================
;; Tree and text helpers
;; ============================================================================================

(define (block-kids b)
  (cond
    [(document? b) (document-children b)]
    [(block-quote? b) (block-quote-children b)]
    [(list-block? b) (list-block-children b)]
    [(list-item? b) (list-item-children b)]
    [(table? b) (append (table-head b) (apply append (table-rows b)))]
    [else '()]))

;; Every block of the document in preorder, and a hash from each block to its parent.
(define (blocks+parents doc)
  (define parents (make-hasheq))
  (define acc '())
  (let walk ([b doc])
    (for ([k (in-list (block-kids b))])
      (hash-set! parents k b)
      (set! acc (cons k acc))
      (walk k)))
  (values (reverse acc) parents))

(define (leaf? b) (or (paragraph? b) (heading? b) (table-cell? b)))
(define (leaf-segments b)
  (cond [(paragraph? b) (paragraph-segments b)] [(heading? b) (heading-segments b)]
        [(table-cell? b) (table-cell-segments b)] [else '()]))
(define (leaf-inlines b)
  (cell-inlines (cond [(paragraph? b) (paragraph-inlines b)] [(heading? b) (heading-inlines b)]
                      [else (table-cell-inlines b)])))

;; A leaf's source ranges (start . end) holding its content, in order (virtual spaces excluded).
(define (leaf-ranges b)
  (for/list ([g (in-list (leaf-segments b))] #:when (> (segment-source-length g) 0))
    (cons (segment-source-start g) (+ (segment-source-start g) (segment-source-length g)))))

(define (in-ranges? ranges p) (for/or ([r (in-list ranges)]) (and (<= (car r) p) (< p (cdr r)))))

(define (line-start text p)
  (let loop ([i p]) (if (and (> i 0) (not (eqv? (string-ref text (sub1 i)) #\newline))) (loop (sub1 i)) i)))
(define (line-end text p)
  (define n (string-length text))
  (let loop ([i p]) (if (and (< i n) (not (eqv? (string-ref text i) #\newline))) (loop (add1 i)) i)))

;; The starts of the lines a selection touches; a selection ending at a line start (after the
;; line ending) does not include that line.
(define (selection-lines text start0 end0)
  (define n (string-length text))
  (define start (min start0 n)) (define end (max start (min end0 n)))
  (define last-pos (if (and (> end start) (eqv? (string-ref text (sub1 end)) #\newline)) (sub1 end) end))
  (let loop ([ls (line-start text start)] [acc '()])
    (define le (line-end text ls))
    (if (or (>= le last-pos) (>= le n))
        (reverse (cons ls acc))
        (loop (add1 le) (cons ls acc)))))

(define (skip-spaces text p limit)
  (if (and (< p limit) (memv (string-ref text p) '(#\space #\tab))) (skip-spaces text (add1 p) limit) p))

(define (blank-line? text ls le)
  (for/and ([c (in-string text ls le)]) (memv c '(#\space #\tab #\>))))

;; The column of position p on the line starting at ls (tabs to the next multiple of 4).
(define (column-at text ls p)
  (for/fold ([col 0]) ([c (in-string text ls p)])
    (if (eqv? c #\tab) (+ col (- 4 (modulo col 4))) (add1 col))))

;; The position on the line [ls, le) where column `col` is reached walking through its prefix
;; (spaces, tabs, `>`), or the first other character before it.
(define (position-at-column text ls le col)
  (let loop ([i ls] [c 0])
    (cond
      [(or (>= i le) (>= c col)) i]
      [else
       (define ch (string-ref text i))
       (case ch
         [(#\space #\>) (loop (add1 i) (add1 c))]
         [(#\tab) (loop (add1 i) (+ c (- 4 (modulo c 4))))]
         [else i])])))

;; ============================================================================================
;; Inline formatting: toggle-emphasis-edits
;; ============================================================================================

(define (kind-pred kind)
  (case kind [(emph) emph?] [(strong) strong?] [(strike) strike?] [(code) code-span?]))
(define (kind-delim kind)
  (case kind [(emph) "*"] [(strong) "**"] [(strike) "~~"] [(code) "`"]))

(define (inline-kids x)
  (cond
    [(emph? x) (emph-children x)] [(strong? x) (strong-children x)] [(strike? x) (strike-children x)]
    [(link? x) (link-children x)] [(image? x) (image-children x)]
    [else '()]))

(define (flatten-inlines xs)
  (append-map (lambda (x) (cons x (flatten-inlines (inline-kids x)))) xs))

(define (find-token x role) (for/first ([t (in-list (inline-tokens x))] #:when (eq? (token-role t) role)) t))

;; The range of a node's children, where a selection may lie without disturbing the node; #f
;; for nodes whose inside is not formattable (code, raw HTML, autolinks, wiki links, tags...).
(define (inner-range x)
  (cond
    [(or (emph? x) (strong? x) (strike? x))
     (define ts (inline-tokens x))
     (cons (token-end (first ts)) (token-start (last ts)))]
    [(or (and (link? x) (memq (link-kind x) '(inline full collapsed shortcut))) (image? x))
     (define o (find-token x 'link-open)) (define c (find-token x 'link-close))
     (and o c (cons (token-end o) (token-start c)))]
    [else #f]))

;; Moves the selection's ends out of nodes it only partly covers (a link whose text it enters,
;; a code span, an escape or entity), so inserted delimiters never split a construct.
(define (snap-selection s e nodes pred)
  (let loop ([s s] [e e])
    (define-values (s2 e2)
      (for/fold ([s s] [e e]) ([x (in-list nodes)] #:unless (pred x))
        (cond
          [(text? x)
           (for/fold ([s s] [e e]) ([t (in-list (inline-tokens x))])
             (define a (token-start t))
             (define b (case (token-role t) [(escape) (+ 2 a)] [(entity) (token-end t)] [else a]))
             (values (if (< a s b) a s) (if (< a e b) b e)))]
          [else
           (define xs (inline-start x)) (define xe (inline-end x))
           (define in (inner-range x))
           (define inside? (and in (<= (car in) s) (<= e (cdr in))))
           (values (if (and (< xs s xe) (not inside?)) xs s)
                   (if (and (< xs e xe) (not inside?)) xe e))])))
    (if (and (= s s2) (= e e2)) (values s e) (loop s2 e2))))

;; A position counts as blank for trimming when it is whitespace or outside the leaf's content
;; (a container prefix between two lines).
(define (blank-at? text ranges p)
  (or (not (in-ranges? ranges p)) (char-whitespace? (string-ref text p))))
(define (trim-forward text ranges p limit)
  (if (and (< p limit) (blank-at? text ranges p)) (trim-forward text ranges (add1 p) limit) p))
(define (trim-backward text ranges p limit)
  (if (and (> p limit) (blank-at? text ranges (sub1 p))) (trim-backward text ranges (sub1 p) limit) p))

(define (word-char? c) (or (char-alphabetic? c) (char-numeric? c) (memv c (list #\' (integer->char #x2019)))))

;; The selection within one leaf, trimmed of blanks and of the kind's own delimiters at its
;; edges (selecting `**bold**` whole means the bold text), snapped out of other constructs.
(define (leaf-selection text leaf start end kind)
  (define ranges (leaf-ranges leaf))
  (and (pair? ranges)
       (let* ([lo (car (first ranges))] [hi (cdr (last ranges))]
              [s0 (max start lo)] [e0 (min end hi)])
         (and (< s0 e0)
              (let* ([pred (kind-pred kind)]
                     [nodes (flatten-inlines (leaf-inlines leaf))]
                     [knodes (filter pred nodes)])
                (define (past-open p)
                  (or (for/first ([k (in-list knodes)]
                                  #:when (let ([t (first (inline-tokens k))]) (<= (token-start t) p (sub1 (token-end t)))))
                        (token-end (first (inline-tokens k))))
                      p))
                (define (before-close p)
                  (or (for/first ([k (in-list knodes)]
                                  #:when (let ([t (last (inline-tokens k))]) (<= (add1 (token-start t)) p (token-end t))))
                        (token-start (last (inline-tokens k))))
                      p))
                (let* ([s1 (past-open (trim-forward text ranges s0 e0))]
                       [e1 (before-close (trim-backward text ranges e0 s1))]
                       [s2 (trim-forward text ranges s1 e1)]
                       [e2 (trim-backward text ranges e1 s2)])
                  ;; code is literal, so it never cuts through other markup; the other kinds are
                  ;; placed well-nested around emphasis they cut through (split-edits)
                  (define keep (if (eq? kind 'code) pred (lambda (x) (or (emph? x) (strong? x) (strike? x)))))
                  (and (< s2 e2)
                       (let-values ([(s3 e3) (snap-selection s2 e2 nodes keep)])
                         (list leaf ranges s3 e3 knodes)))))))))

(define (covered? text ranges s e knodes)
  (for/and ([p (in-range s e)] #:unless (blank-at? text ranges p))
    (for/or ([k (in-list knodes)]) (and (<= (inline-start k) p) (< p (inline-end k))))))

(define (token-text text t) (substring text (token-start t) (token-end t)))

;; A kept delimiter token rewritten to the canonical delimiter when it differs (`_` cannot
;; close intraword; `~` must match `~~` in count), so kept and inserted delimiters pair up.
(define (canonical-token text t delim)
  (if (equal? (token-text text t) delim) '() (list (edit (token-start t) (token-end t) delim))))

;; Code delimiters long enough for the text they wrap.
(define (code-delims text [s 0] [e (string-length text)])
  (define longest
    (let loop ([i s] [run 0] [best 0])
      (cond [(>= i e) (max run best)]
            [(eqv? (string-ref text i) #\`) (loop (add1 i) (add1 run) best)]
            [else (loop (add1 i) 0 (max run best))])))
  (define ticks (make-string (add1 longest) #\`))
  (define pad? (and (> longest 0) (or (eqv? (string-ref text s) #\`) (eqv? (string-ref text (sub1 e)) #\`))))
  (values (if pad? (string-append ticks " ") ticks) (if pad? (string-append " " ticks) ticks)))

(define (outermost ks)
  (filter (lambda (k) (not (for/or ([o (in-list ks)])
                             (and (not (eq? o k)) (<= (inline-start o) (inline-start k))
                                  (<= (inline-end k) (inline-end o))))))
          ks))

(define (wrap-edits text kind sel)
  (define-values (leaf ranges s e knodes) (apply values sel))
  ;; same-kind nodes overlapping the selection, touching it, or separated from it by blanks only
  ;; (code spans only when they overlap: code is literal, its neighbors stay apart)
  (define code? (eq? kind 'code))
  (define lo (if code? (add1 s) (trim-backward text ranges s (car (first ranges)))))
  (define hi (if code? (sub1 e) (trim-forward text ranges e (cdr (last ranges)))))
  ;; A neighbor merges only when written with the canonical delimiters: rewriting `_x_` to `*x*`
  ;; could not be undone by toggling back.
  (define (canonical? k)
    (for/and ([t (in-list (inline-tokens k))]) (equal? (token-text text t) (kind-delim kind))))
  (define m (filter (lambda (k) (or (and (< (inline-start k) e) (> (inline-end k) s))
                                    (and (<= (inline-start k) hi) (>= (inline-end k) lo) (canonical? k))))
                    knodes))
  (define us (apply min s (map inline-start m)))
  (define ue (apply max e (map inline-end m)))
  ;; code delimiters are re-sized to the new content, so none is kept
  (define keep-open (and (not code?) (for/first ([k (in-list m)] #:when (= (inline-start k) us)) k)))
  (define keep-close (and (not code?) (for/first ([k (in-list (reverse m))] #:when (= (inline-end k) ue)) k)))
  (define-values (open close)
    (if code?
        (code-delims (let ([gone (append-map inline-tokens m)])
                       (list->string (for/list ([p (in-range us ue)]
                                                #:unless (for/or ([t (in-list gone)]) (<= (token-start t) p (sub1 (token-end t)))))
                                       (string-ref text p)))))
        (let ([d (kind-delim kind)]) (values d d))))
  (append
   (for*/list ([k (in-list m)] [t (in-list (list (first (inline-tokens k)) (last (inline-tokens k))))]
               #:unless (or (and (eq? k keep-open) (eq? t (first (inline-tokens k))))
                            (and (eq? k keep-close) (eq? t (last (inline-tokens k))))))
     (edit (token-start t) (token-end t) ""))
   (if keep-open
       (if (eq? kind 'code) '() (canonical-token text (first (inline-tokens keep-open)) open))
       (list (edit us us open)))
   (if keep-close
       (if (eq? kind 'code) '() (canonical-token text (last (inline-tokens keep-close)) close))
       (list (edit ue ue close)))))

(define (unwrap-edits text kind sel)
  (define-values (leaf ranges s e knodes) (apply values sel))
  (define hit (outermost (filter (lambda (k) (and (< (inline-start k) e) (> (inline-end k) s))) knodes)))
  (append*
   (for/list ([k (in-list hit)])
     (define open (first (inline-tokens k))) (define close (last (inline-tokens k)))
     (define in-s (token-end open)) (define in-e (token-start close))
     (define left-end (trim-backward text ranges (max in-s (min s in-e)) in-s))
     (define right-start (trim-forward text ranges (min in-e (max e in-s)) in-e))
     (define d (if (eq? kind 'code) #f (kind-delim kind)))
     (append
      (if (> left-end in-s)
          (append (if d (canonical-token text open d) '())
                  (list (edit left-end left-end (or d (token-text text close)))))
          (list (edit (token-start open) (token-end open) "")))
      (if (< right-start in-e)
          (append (list (edit right-start right-start (or d (token-text text open))))
                  (if d (canonical-token text close d) '()))
          (list (edit (token-start close) (token-end close) "")))))))

;; Toggles `kind` ('strong 'emph 'strike 'code) on [start, end), or on the word at the caret
;; when start = end. If every content character selected is already of that kind the kind is
;; removed from the selection (a node reaching beyond it is split around it), otherwise the
;; selection gets it, merged with same-kind nodes it overlaps or touches; other emphasis and
;; links it cuts through stay whole (see split-edits). A caret outside any word inserts an
;; empty pair, and toggling again at its middle removes it. Returns the edits and the
;; selection in the new text (the same characters, now or no longer formatted), so toggling
;; twice with the returned selection gives back the original text (split-edits says when).
(define (toggle-emphasis-edits doc start0 end0 kind)
  (define text (document-text doc))
  (define start (min start0 (string-length text)))
  (define end (max start (min end0 (string-length text))))
  (define-values (blocks parents) (blocks+parents doc))
  (define leaves (filter leaf? blocks))
  (cond
    [(= start end)
     (define c start)
     (define d (kind-delim kind))
     (define dl (string-length d))
     (define leaf (for/first ([b (in-list leaves)]
                              #:when (for/or ([r (in-list (leaf-ranges b))]) (<= (car r) c (cdr r))))
                    b))
     (define (word-bounds)
       (define ranges (leaf-ranges leaf))
       (define (wc? p) (and (in-ranges? ranges p) (word-char? (string-ref text p))))
       (define ws (let loop ([p c]) (if (and (> p 0) (wc? (sub1 p))) (loop (sub1 p)) p)))
       (define we (let loop ([p c]) (if (and (< p (string-length text)) (wc? p)) (loop (add1 p)) p)))
       (values ws we))
     (cond
       [(and (>= (- c dl) 0) (<= (+ c dl) (string-length text))
             (equal? (substring text (- c dl) c) d) (equal? (substring text c (+ c dl)) d))
        (values (list (edit (- c dl) (+ c dl) "")) (- c dl) (- c dl))]
       [(not leaf) (values (list (edit c c (string-append d d))) (+ c dl) (+ c dl))]
       [else
        (define-values (ws we) (word-bounds))
        (cond
          [(= ws we) (values (list (edit c c (string-append d d))) (+ c dl) (+ c dl))]
          [else
           (define edits (toggle-range doc text leaves ws we kind))
           (define nc (map-position edits c (if (= c we) 'before 'after)))
           (values edits nc nc)])])]
    [else
     (define edits (toggle-range doc text leaves start end kind))
     (define ns (map-position edits start 'after))
     (define ne (map-position edits end 'before))
     (values edits (min ns ne) (max ns ne))]))

(define (toggle-range doc text leaves start end kind)
  (define sels
    (filter values (for/list ([b (in-list leaves)] #:when (and (< (block-start b) end) (> (block-end b) start)))
                     (leaf-selection text b start end kind))))
  (cond
    [(eq? kind 'code)
     (define unwrap?
       (and (pair? sels)
            (for/and ([sel (in-list sels)])
              (define-values (leaf ranges s e knodes) (apply values sel))
              (covered? text ranges s e knodes))))
     (normalize-edits text (append-map (lambda (sel) ((if unwrap? unwrap-edits wrap-edits) text kind sel)) sels))]
    [else
     (define infos (filter (lambda (i) (pair? (linfo-sel-cps i))) (for/list ([sel (in-list sels)]) (leaf-content text sel))))
     (define unwrap? (and (pair? infos) (for/and ([i (in-list infos)]) (content-covered? i))))
     (normalize-edits text (append-map (lambda (i) (split-edits text doc kind i unwrap?)) infos))]))

;; --- strong, emph, strike: formatting as a set of content characters ---
;;
;; The leaf's content characters are those that are neither blank nor inside a markup token
;; (delimiters, link syntax, code backticks); escapes and entities are content. Toggling
;; changes which content characters carry the kind: the nodes of the kind the selection
;; overlaps (and, when adding, canonical ones next to that with only blanks and markup between)
;; are taken apart, and the characters that should carry the kind get new delimiters, placed
;; well-nested in the remaining tree: a run of them that ends inside other emphasis, or a
;; link's text, is closed before it and continued inside it, never across it. A new delimiter
;; landing where a removed one was keeps that one (rewritten to the canonical delimiter), so a
;; diff touches only the delimiters it must. Toggling twice is the identity on documents
;; without redundant markup (the kind nested in itself, or two nodes of the kind separated by
;; blanks only, which a toggle merges).
(struct linfo (leaf lo content sel-cps s e knodes nodes) #:transparent)

(define (leaf-content text sel)
  (define-values (leaf ranges s e knodes) (apply values sel))
  (define lo (car (first ranges))) (define hi (cdr (last ranges)))
  (define nodes (flatten-inlines (leaf-inlines leaf)))
  (define v (make-vector (- hi lo) #f))
  (for ([p (in-range lo hi)])
    (vector-set! v (- p lo) (and (in-ranges? ranges p) (not (char-whitespace? (string-ref text p))))))
  (for* ([x (in-list nodes)] [t (in-list (inline-tokens x))] #:unless (memq (token-role t) '(escape entity)))
    (for ([p (in-range (max lo (token-start t)) (min hi (token-end t)))]) (vector-set! v (- p lo) #f)))
  (define sel-cps (for/list ([p (in-range (max s lo) (min e hi))] #:when (vector-ref v (- p lo))) p))
  (linfo leaf lo v sel-cps s e knodes nodes))

(define (content? i p)
  (define k (- p (linfo-lo i)))
  (and (<= 0 k) (< k (vector-length (linfo-content i))) (vector-ref (linfo-content i) k)))
(define (node-cps i x) (for/list ([p (in-range (inline-start x) (inline-end x))] #:when (content? i p)) p))
(define (in-node? x p) (and (<= (inline-start x) p) (< p (inline-end x))))

(define (content-covered? i)
  (and (pair? (linfo-sel-cps i))
       (for/and ([p (in-list (linfo-sel-cps i))]) (for/or ([k (in-list (linfo-knodes i))]) (in-node? k p)))))

(define (split-edits text doc kind i unwrap?)
  (define d (kind-delim kind))
  (define sel (linfo-sel-cps i))
  (define knodes (linfo-knodes i))
  (define all-cps (for/list ([p (in-range (linfo-lo i) (+ (linfo-lo i) (vector-length (linfo-content i))))]
                             #:when (content? i p))
                    p))
  (define (canonical? k) (for/and ([t (in-list (inline-tokens k))]) (equal? (token-text text t) d)))
  (define alt (case kind [(emph) "_"] [(strong) "__"] [else #f]))
  (define (dchar k) (string-ref text (token-start (first (inline-tokens k)))))
  ;; a node is written in the current form: `*`/`**` or `_`/`__` (strikethrough: `~~` only)
  (define current-form (make-parameter #\*))
  (define (form? k)
    (define want (if (and alt (eqv? (current-form) #\_)) alt d))
    (for/and ([t (in-list (inline-tokens k))]) (equal? (token-text text t) want)))
  (define overlapping (filter (lambda (k) (for/or ([p (in-list sel)]) (in-node? k p))) knodes))
  ;; the affected nodes, and the content characters that carry the kind afterwards among theirs
  (define-values (affected target)
    (cond
      [(null? sel) (values '() '())]
      [unwrap?
       (define aff overlapping)
       (values aff (filter (lambda (p) (and (not (memv p sel)) (for/or ([k (in-list aff)]) (in-node? k p)))) all-cps))]
      [else
       ;; the inline parent of each node, to tell pieces of one split run from siblings
       (define parents (make-hasheq))
       (let walk ([xs (leaf-inlines (linfo-leaf i))] [p #f])
         (for ([x (in-list xs)]) (hash-set! parents x p) (walk (inline-kids x) x)))
       ;; a neighbor merges only from a container around the selection or one the selection
       ;; enters: merging one inside a container the selection is outside of would move the
       ;; neighbor's delimiters out of it
       (define sel-container
         (for/fold ([best #f]) ([x (in-list (linfo-nodes i))]
                                #:when (and (inner-range x) (in-node? x (first sel)) (in-node? x (last sel))))
           (if (or (not best) (< (- (inline-end x) (inline-start x)) (- (inline-end best) (inline-start best)))) x best)))
       (define outer (let loop ([x sel-container]) (if x (cons x (loop (hash-ref parents x #f))) '(#f))))
       ;; a node's parent, passing a parent with the same content written with the same
       ;; character (`***x***` parses as emphasis around strong, however it was meant)
       (define (eff-parent k)
         (define ks (node-cps i k))
         (define (ch x) (let ([t (first (inline-tokens x))]) (string-ref text (token-start t))))
         (let loop ([p (hash-ref parents k #f)])
           (if (and p (or (emph? p) (strong? p) (strike? p)) (equal? (node-cps i p) ks) (eqv? (ch p) (ch k)))
               (loop (hash-ref parents p #f))
               p)))
       (define (between a b) (for/or ([p (in-list all-cps)]) (and (< a p) (< p b))))
       (define (cluster-of aff) (sort (remove-duplicates (append sel (append-map (lambda (k) (node-cps i k)) aff))) <))
       ;; canonical nodes of the kind outside [c-lo, c-hi] with only blanks and markup between
       (define (neighbors aff c-lo c-hi ok?)
         (filter (lambda (k)
                   (define ps (node-cps i k))
                   (and (not (memq k aff)) (form? k) (pair? ps) (ok? k)
                        (let ([pk (eff-parent k)])
                          (or (memq pk outer) (for/or ([p (in-list sel)]) (in-node? pk p))))
                        (or (and (< (last ps) c-lo) (not (between (last ps) c-lo)))
                            (and (> (first ps) c-hi) (not (between c-hi (first ps)))))))
                 knodes))
       ;; neighbors merge when written like the nodes the selection overlaps (or, without any,
       ;; like each other, `*` first): rewriting `_x_` to `*x*` could not be undone
       (define run-char
         (cond [(pair? overlapping) (dchar (first overlapping))]
               [else (define c (cluster-of '()))
                     (define (any-of ch) (parameterize ([current-form ch]) (pair? (neighbors '() (first c) (last c) (lambda (k) #t)))))
                     (if (or (any-of #\*) (not (any-of #\_))) #\* #\_)]))
       (current-form run-char)
       ;; the neighbors of the selection merge; beyond them, only a neighbor in another container
       ;; (a piece of one run that a container boundary split, as unwrapping leaves them)
       (define aff
         (let loop ([aff (let ([c (cluster-of overlapping)])
                           (append overlapping (neighbors overlapping (first c) (last c) (lambda (k) #t))))]
                    [fresh #f])
           (define new (if fresh fresh (filter (lambda (k) (not (memq k overlapping))) aff)))
           (define c (cluster-of aff))
           (define more
             (remove-duplicates
              (append-map (lambda (n)
                            (define ps (node-cps i n))
                            (neighbors aff (first c) (last c)
                                       (lambda (k) (and (not (eq? (eff-parent k) (eff-parent n)))
                                                        (let ([ks (node-cps i k)])
                                                          (or (and (< (last ks) (first ps)) (not (between (last ks) (first ps))))
                                                              (and (> (first ks) (last ps)) (not (between (last ps) (first ks))))))))))
                          new)
              eq?))
           (if (null? more) aff (loop (append aff more) more))))
       (values aff (cluster-of aff))]))
  ;; runs of target characters with no other content character between them
  (define runs
    (let loop ([ps all-cps] [cur '()] [acc '()])
      (define (flush) (if (null? cur) acc (cons (reverse cur) acc)))
      (cond [(null? ps) (reverse (flush))]
            [(memv (car ps) target) (loop (cdr ps) (cons (car ps) cur) acc)]
            [else (loop (cdr ps) '() (flush))])))
  ;; the tree without the affected nodes
  (define (kids-of xs) (append-map (lambda (x) (if (memq x affected) (kids-of (inline-kids x)) (list x))) xs))
  (define (container? x) (and (not (memq x affected)) (inner-range x) (not (null? (inline-kids x)))))
  (define (first-content x) (for/first ([p (in-range (inline-start x) (inline-end x))] #:when (content? i p)) p))
  (define (last-content x) (for/last ([p (in-range (inline-start x) (inline-end x))] #:when (content? i p)) p))
  (define (start-pos x) (if (text? x) (first-content x) (inline-start x)))
  (define (end-pos x) (if (text? x) (add1 (last-content x)) (inline-end x)))
  ;; pairs (open . close) wrapping the content [a, b) among `kids`: a container whose content
  ;; the run covers is wrapped whole (the kind goes outside other emphasis and links: `**_x_**`,
  ;; not `_**x**_`), one it covers part of is closed before and continued inside. With
  ;; `inside?`, containers at the run's ends are entered even when covered (`x~~**y**~~` where
  ;; `x**~~y~~**` could not open).
  (define (place kids a b inside?)
    (define (kid-at p) (for/first ([x (in-list kids)] #:when (in-node? x p)) x))
    (define ka (kid-at a)) (define kb (kid-at (sub1 b)))
    (define (whole-from? x) (and (not inside?) (= a (first-content x))))
    (define (whole-to? x) (and (not inside?) (= b (add1 (last-content x)))))
    (cond
      [(and (eq? ka kb) (container? ka) (not (and (whole-from? ka) (whole-to? ka))))
       (place (kids-of (inline-kids ka)) a b inside?)]
      [else
       (define with-content (filter first-content kids))
       (define-values (lo left)
         (cond [(text? ka) (values a '())]
               [(or (not (container? ka)) (whole-from? ka)) (values (inline-start ka) '())]
               [else (values (start-pos (cadr (memq ka with-content)))
                             (place (kids-of (inline-kids ka)) a (add1 (last-content ka)) inside?))]))
       (define-values (hi right)
         (cond [(text? kb) (values b '())]
               [(or (not (container? kb)) (whole-to? kb)) (values (inline-end kb) '())]
               [else (values (end-pos (cadr (memq kb (reverse with-content))))
                             (place (kids-of (inline-kids kb)) (first-content kb) b inside?))]))
       (append left right (if (< lo hi) (list (cons lo hi)) '()))]))
  (define (pairs-for inside?)
    (append* (for/list ([r (in-list runs)])
               (place (kids-of (leaf-inlines (linfo-leaf i))) (first r) (add1 (last r)) inside?))))
  ;; edits for `pairs` with delimiters `ds` (one per pair): a removed delimiter where a new one
  ;; goes is kept (rewritten if it differs), the others deleted
  (define opens (map (lambda (k) (first (inline-tokens k))) affected))
  (define closes (map (lambda (k) (last (inline-tokens k))) affected))
  (define (emit pairs ds)
    (define kept (make-hasheq))
    (define (reuse toks pos at)
      (for/first ([t (in-list toks)] #:when (and (not (hash-ref kept t #f)) (= (at t) pos)))
        (hash-set! kept t #t)
        t))
    (define inserts
      (append*
       (for/list ([pr (in-list pairs)] [d (in-list ds)])
         (define o (reuse opens (car pr) token-end))
         (define c (reuse closes (cdr pr) token-start))
         (append (if o (canonical-token text o d) (list (edit (car pr) (car pr) d)))
                 (if c (canonical-token text c d) (list (edit (cdr pr) (cdr pr) d)))))))
    (normalize-edits text (append inserts
                                  (for/list ([t (in-list (append opens closes))] #:unless (hash-ref kept t #f))
                                    (edit (token-start t) (token-end t) "")))))
  ;; The candidates, in order: each pair written like a delimiter it keeps, then all with `*`,
  ;; then some with `_` (where `*` would join a neighboring `*` run: `**x**` closed right
  ;; before a `*x*` opener), then the same entering containers at the run's ends. The first
  ;; that parses as intended wins (flanking rules and the rule of 3 decide, not guesses).
  (define (candidates pairs)
    (define n (length pairs))
    (define preferred
      (for/list ([pr (in-list pairs)])
        (define t (or (for/first ([t (in-list opens)] #:when (= (token-end t) (car pr))) t)
                      (for/first ([t (in-list closes)] #:when (= (token-start t) (cdr pr))) t)))
        (if (and t alt (eqv? (string-ref text (token-start t)) #\_)) alt d)))
    (for/list ([ds (in-list (list* preferred (make-list n d)
                                   (if alt
                                       (for/list ([m (in-range 1 (expt 2 (min n 4)))])
                                         (for/list ([k (in-range n)]) (if (bitwise-bit-set? m k) alt d)))
                                       '())))])
      (lambda () (emit pairs ds))))
  (define outside (pairs-for #f))
  (define all (append (candidates outside) (candidates (pairs-for #t))))
  ;; none: the markup cannot say it without touching the text (emphasis glued inside a word,
  ;; `note~~due~~` cut at the `~~`), so this leaf is left alone rather than broken
  (or (for/or ([c (in-list all)]) (let ([es (c)]) (and (parses-as-intended? text doc i kind unwrap? es) es)))
      '()))

;; Whether the leaf, once `edits` are applied, has each content character formatted as before,
;; the selected ones with `kind` added (or removed, `unwrap?`), and no delimiter left over as text: its new content is
;; parsed again (design §4.4: the edits are checked, not trusted).
(define (parses-as-intended? text doc i kind unwrap? edits)
  (define leaf (linfo-leaf i))
  (define cell (cond [(paragraph? leaf) (paragraph-inlines leaf)] [(heading? leaf) (heading-inlines leaf)]
                     [else (table-cell-inlines leaf)]))
  (define segs (inline-cell-segments cell))
  (define (src->off p)
    (or (for/first ([g (in-list segs)]
                    #:when (<= (segment-source-start g) p (+ (segment-source-start g) (segment-source-length g))))
          (+ (segment-content-start g) (min (segment-content-length g) (- p (segment-source-start g)))))
        0))
  (define content-edits (for/list ([e (in-list edits)]) (edit (src->off (edit-start e)) (src->off (edit-end e)) (edit-text e))))
  (define new-content (apply-edits (inline-cell-content cell) content-edits))
  (define opts (inline-options (document-extensions doc)
                               (cond [(paragraph? leaf) 'paragraph] [(heading? leaf) 'heading] [else 'table-cell])
                               '() '()))
  (define (table s inlines)
    (define h (make-hasheqv))
    (let walk ([xs inlines] [ks '()])
      (for ([x (in-list xs)])
        (define (mark! a b ks)
          (for ([o (in-range a b)] #:unless (char-whitespace? (string-ref s o)))
            (hash-set! h o (cons (string-ref s o) (sort ks symbol<?)))))
        (cond
          [(text? x) (mark! (inline-start x) (inline-end x) ks)]
          [(code-span? x) (let ([ts (inline-tokens x)]) (mark! (token-end (first ts)) (token-start (last ts)) (cons 'code ks)))]
          [(emph? x) (walk (emph-children x) (cons 'emph ks))]
          [(strong? x) (walk (strong-children x) (cons 'strong ks))]
          [(strike? x) (walk (strike-children x) (cons 'strike ks))]
          [else (walk (inline-kids x) ks)])))
    h)
  (define old (table (inline-cell-content cell) (cell-relative-inlines cell)))
  (define new (table new-content (parse-inlines new-content (document-refmap doc) opts)))
  (define selected (for/hasheqv ([p (in-list (linfo-sel-cps i))]) (values (src->off p) #t)))
  (define (delims h) (for/sum ([v (in-hash-values h)]) (if (memv (car v) '(#\* #\_ #\~)) 1 0)))
  (and (= (delims old) (delims new))
       (for/and ([(o v) (in-hash old)])
         (define ks (cdr v))
         (define want (if (hash-ref selected o #f)
                          (cond [unwrap? (remq kind ks)]
                                [(memq kind ks) ks]
                                [else (sort (cons kind ks) symbol<?)])
                          ks))
         (equal? (hash-ref new (map-position content-edits o 'after) #f) (cons (car v) want)))))

;; ============================================================================================
;; Headings: set-heading-level-edits
;; ============================================================================================

(define (hashes n) (make-string n #\#))

;; Sets the heading level (1-6), or makes body text (0), for every heading and paragraph line
;; the selection touches: an ATX heading's opening `#`s are replaced, a setext underline is
;; rewritten (levels 1-2) or turned into an ATX marker (3-6), a paragraph line gets `#`s.
(define (set-heading-level-edits doc start end level)
  (define text (document-text doc))
  (define-values (blocks parents) (blocks+parents doc))
  (define (touches? b) (and (<= (block-start b) end) (>= (block-end b) start)))
  (normalize-edits
   text
   (append*
    (for/list ([b (in-list blocks)] #:when (and (or (heading? b) (paragraph? b)) (touches? b)))
      (define ranges (leaf-ranges b))
      (cond
        [(and (heading? b) (not (heading-setext? b)))
         (define ms (filter (lambda (t) (eq? (token-role t) 'heading-marker)) (block-tokens b)))
         (define open (and (pair? ms) (first ms)))
         (define close (and (pair? ms) (pair? ranges) (> (length ms) 1) (last ms)))
         (cond
           [(not open) '()]
           [(> level 0) (list (edit (token-start open) (token-end open) (hashes level)))]
           [else
            (define content-start (if (pair? ranges) (car (first ranges)) (block-end b)))
            (append (list (edit (token-start open) content-start ""))
                    (if close (list (edit (cdr (last ranges)) (token-end close) "")) '()))])]
        [(heading? b) ; setext
         (define u (for/first ([t (in-list (block-tokens b))] #:when (eq? (token-role t) 'setext-underline)) t))
         (define content-end (if (pair? ranges) (cdr (last ranges)) (block-start b)))
         (define underline-line (edit content-end (block-end b) ""))
         (cond
           [(not u) '()]
           [(memv level '(1 2))
            (list (edit (token-start u) (token-end u)
                        (make-string (- (token-end u) (token-start u)) (if (= level 1) #\= #\-))))]
           [(= level 0) (list underline-line)]
           [else
            ;; one ATX line: the content's line breaks (and their container prefixes) become spaces
            (append (list (edit (car (first ranges)) (car (first ranges)) (string-append (hashes level) " ")))
                    (for/list ([a (in-list ranges)] [b (in-list (cdr ranges))]) (edit (cdr a) (car b) " "))
                    (list underline-line))])]
        [(= level 0) '()]
        [else ; paragraph: each touched line becomes a heading
         (for/list ([r (in-list ranges)]
                    #:when (<= (line-start text (car r)) end)
                    #:when (>= (line-end text (car r)) start))
           (edit (car r) (car r) (string-append (hashes level) " ")))])))))

;; ============================================================================================
;; List items: markers, task markers, entries per line
;; ============================================================================================

(define (item-marker item)
  (for/first ([t (in-list (block-tokens item))] #:when (memq (token-role t) '(bullet ordered-marker))) t))

;; `[ ]`, `[x]`, `[X]` or `[-]` at p followed by a space, a tab or the line's end.
(define (task-text-at? text p)
  (define n (string-length text))
  (and (< (+ p 2) n)
       (eqv? (string-ref text p) #\[) (eqv? (string-ref text (+ p 2)) #\])
       (memv (string-ref text (add1 p)) '(#\space #\x #\X #\-))
       (or (= (+ p 3) n) (memv (string-ref text (+ p 3)) '(#\space #\tab #\newline)))))

;; The start of an item's task marker: its `task-marker` token (tasks extension on), or the same
;; text where the item's content begins on its marker line.
(define (item-task-pos text item)
  (define m (item-marker item))
  (or (for/first ([t (in-list (block-tokens item))] #:when (eq? (token-role t) 'task-marker)) (token-start t))
      (and m (let ([p (skip-spaces text (token-end m) (line-end text (token-end m)))])
               (and (> p (token-end m)) (task-text-at? text p) p)))))

;; Where the item's text begins on its marker line: after the marker, its spaces, and the task
;; marker with its spaces (unless `keep-task?`).
(define (item-content-pos text item [keep-task? #f])
  (define m (item-marker item))
  (define le (line-end text (token-end m)))
  (define p (skip-spaces text (token-end m) le))
  (define tp (item-task-pos text item))
  (if (and tp (not keep-task?)) (skip-spaces text (+ tp 3) le) p))

(define (item-state text item)
  (cond [(item-task-pos text item) 'task]
        [(eq? (token-role (item-marker item)) 'ordered-marker) 'ordered]
        [else 'bullet]))

;; The number and delimiter of an ordered marker token.
(define (marker-number text m)
  (define s (token-text text m))
  (values (string->number (substring s 0 (sub1 (string-length s)))) (substring s (sub1 (string-length s)))))

;; Per line of the selection: (list 'item line-start item) for a line holding a list marker (the
;; innermost), (list 'plain line-start pos) for a paragraph or heading line outside list items'
;; bodies, where `pos` is where its text begins; other lines are left out.
(define (line-entries doc start end)
  (define text (document-text doc))
  (define-values (blocks parents) (blocks+parents doc))
  (define items (make-hash))  ; line start -> innermost item with its marker there
  (define plains (make-hash)) ; line start -> first text position
  (define (inside-item? b) (let loop ([p (hash-ref parents b #f)])
                             (and p (or (list-item? p) (loop (hash-ref parents p #f))))))
  (for ([b (in-list blocks)])
    (cond
      [(list-item? b) (hash-set! items (line-start text (token-start (item-marker b))) b)]
      [(and (or (paragraph? b) (heading? b)) (not (inside-item? b)))
       (define open (and (heading? b) (not (heading-setext? b))
                         (for/first ([t (in-list (block-tokens b))] #:when (eq? (token-role t) 'heading-marker)) t)))
       (if open
           (hash-set! plains (line-start text (token-start open)) (token-start open))
           (for ([r (in-list (leaf-ranges b))])
             (hash-ref! plains (line-start text (car r)) (car r))))]))
  (filter values
          (for/list ([ls (in-list (selection-lines text start end))])
            (cond [(hash-ref items ls #f) => (lambda (it) (list 'item ls it))]
                  [(hash-ref plains ls #f) => (lambda (p) (list 'plain ls p))]
                  [else #f]))))

;; ============================================================================================
;; toggle-list-edits, toggle-quote-edits
;; ============================================================================================

;; Makes the lines of the selection bulleted ('bullet), numbered ('ordered) or checklist items
;; ('task), or, when every one of them already is, plain paragraphs again. Lines that are list
;; items of another kind are converted in place (their marker token replaced, a task marker
;; added or removed); numbering continues per list. Only the markers change.
(define (toggle-list-edits doc start end kind)
  (define text (document-text doc))
  (define entries (line-entries doc start end))
  (define (state e) (if (eq? (car e) 'item) (item-state text (caddr e)) 'plain))
  (define all-kind? (and (pair? entries) (for/and ([e (in-list entries)]) (eq? (state e) kind))))
  (define counters (make-hasheq))
  (define (parent-key e) (if (eq? (car e) 'item) (caddr e) 'plain))
  (normalize-edits
   text
   (append*
    (cond
      [all-kind?
       (for/list ([e (in-list entries)])
         (define item (caddr e))
         (list (edit (token-start (item-marker item)) (item-content-pos text item) "")))]
      [else
       ;; numbers per list: the item's list, found through its siblings sharing a counter
       (define-values (blocks parents) (blocks+parents doc))
       (define (counter-key e) (if (eq? (car e) 'item) (hash-ref parents (caddr e)) 'plain))
       (define (next-number! e)
         (define n (hash-ref counters (counter-key e) 1))
         (hash-set! counters (counter-key e) (add1 n))
         n)
       (for/list ([e (in-list entries)])
         (define st (state e))
         (cond
           [(eq? (car e) 'plain)
            (define p (caddr e))
            (list (edit p p (case kind
                              [(bullet) "- "] [(task) "- [ ] "]
                              [(ordered) (format "~a. " (next-number! e))])))]
           [else
            (define item (caddr e))
            (define m (item-marker item))
            (define tp (item-task-pos text item))
            (define content (item-content-pos text item))
            (define remove-task (if tp (list (edit tp content "")) '()))
            (case kind
              [(bullet)
               (append (if (eq? (token-role m) 'ordered-marker) (list (edit (token-start m) (token-end m) "-")) '())
                       remove-task)]
              [(ordered)
               (cond
                 [(eq? st 'ordered)
                  (define-values (n d) (marker-number text m))
                  (hash-set! counters (counter-key e) (add1 n))
                  '()]
                 [else
                  (define n (next-number! e))
                  (append (if (eq? (token-role m) 'ordered-marker)
                              '()
                              (list (edit (token-start m) (token-end m) (format "~a." n))))
                          remove-task)])]
              [(task)
               (cond
                 [tp '()]
                 [else
                  (define p (item-content-pos text item))
                  (list (edit p p (if (= p (token-end m)) " [ ] " "[ ] ")))])])]))]))))

;; Quotes the lines of the selection (`> ` before each, `>` on blank lines between them), or,
;; when every non-blank line already has a quote marker, removes one marker (and the space
;; after it) from each.
(define (toggle-quote-edits doc start end)
  (define text (document-text doc))
  (define-values (blocks parents) (blocks+parents doc))
  (define markers (make-hash)) ; line start -> first quote marker on the line
  (for* ([b (in-list blocks)] #:when (block-quote? b) [t (in-list (block-tokens b))])
    (define ls (line-start text (token-start t)))
    (define cur (hash-ref markers ls #f))
    (when (or (not cur) (< (token-start t) (token-start cur))) (hash-set! markers ls t)))
  (define lines (selection-lines text start end))
  (define (blank? ls) (blank-line? text ls (line-end text ls)))
  (define non-blank (filter (lambda (ls) (not (blank? ls))) lines))
  (define all-quoted? (and (pair? non-blank) (for/and ([ls (in-list non-blank)]) (hash-ref markers ls #f))))
  (normalize-edits
   text
   (cond
     [all-quoted?
      (for/list ([ls (in-list lines)] #:when (hash-ref markers ls #f))
        (define t (hash-ref markers ls))
        (define after (token-end t))
        (edit (token-start t) (if (and (< after (string-length text)) (eqv? (string-ref text after) #\space))
                                  (add1 after) after)
              ""))]
     [(null? non-blank) '()]
     [else
      (define first-ls (first non-blank)) (define last-ls (last non-blank))
      (for/list ([ls (in-list lines)]
                 #:when (<= first-ls ls last-ls)
                 #:unless (hash-ref markers ls #f))
        (edit ls ls (if (blank? ls) ">" "> ")))])))

;; ============================================================================================
;; Enter in a list: list-enter-edits
;; ============================================================================================

;; The blocks containing pos (its end included, as block-at), outermost first.
(define (path-at doc pos)
  (let loop ([b doc] [acc '()])
    (define hit (for/first ([k (in-list (block-kids b))] #:when (<= (block-start k) pos (block-end k))) k))
    (if hit (loop hit (cons hit acc)) (reverse acc))))

(define (item-at doc pos)
  (for/last ([b (in-list (path-at doc pos))] #:when (list-item? b)) b))

;; An empty item: one line, nothing after its marker but an optional task marker (read from
;; the source: a lone `- [ ]` has no whitespace after the brackets, so it is no task node).
(define (empty-item? text item)
  (define m (item-marker item))
  (define le (line-end text (token-end m)))
  (and (<= (block-end item) le)
       (let* ([p (skip-spaces text (token-end m) le)]
              [p (if (and (<= (+ p 3) le) (eqv? (string-ref text p) #\[) (eqv? (string-ref text (+ p 2)) #\])
                          (memv (string-ref text (add1 p)) '(#\space #\x #\X #\-)))
                     (skip-spaces text (+ p 3) le)
                     p)])
         (= p le))))

;; The text before a marker on its line, as a new line's prefix: `>` and tabs kept, everything
;; else (indentation, an outer item's marker) as spaces.
(define (line-prefix text m)
  (list->string (for/list ([c (in-string text (line-start text (token-start m)) (token-start m))])
                  (if (memv c '(#\> #\tab)) c #\space))))

;; Enter at `pos`. Inside a list item's paragraph or heading: the item is split at the caret
;; and the text after it starts a new item of the same kind (same bullet, the next number with
;; the following items renumbered, an open task marker), with the line prefix of the marker's
;; line (block quotes, indentation) and a blank line between items of a loose list. On an
;; empty item: a nested one moves out a level, a top-level one loses its marker, ending the
;; list. Returns the edits and the caret position in the new text, or (values #f #f) outside a
;; list item's text (the editor then inserts a plain line break).
(define (list-enter-edits doc pos)
  (define text (document-text doc))
  (define path (path-at doc pos))
  (define inner (and (pair? path) (last path)))
  (define item
    (cond
      [(and inner (list-item? inner)) inner]
      [(and inner (or (paragraph? inner) (heading? inner)) (>= (length path) 2)
            (list-item? (list-ref path (- (length path) 2))))
       (list-ref path (- (length path) 2))]
      [else #f]))
  (cond
    [(not item) (values #f #f)]
    [else
     (define lst (list-ref path (- (length path) (if (eq? item inner) 2 3))))
     (define outer-item (for/last ([b (in-list path)] #:when (and (list-item? b) (not (eq? b item)))) b))
     (define m (item-marker item))
     (define le (line-end text (token-end m)))
     (cond
       [(empty-item? text item)
        (cond
          [outer-item
           (define edits (outdent-items text (list item) path-parents-for doc))
           (values edits (map-position edits le 'before))]
          [else
           (define edits (normalize-edits text (list (edit (token-start m) le ""))))
           (values edits (token-start m))])]
       [else
        (define content (item-content-pos text item))
        (define c (if (and (<= (line-start text (token-start m)) pos) (< pos content)) content pos))
        (define strip (- (skip-spaces text c (line-end text c)) c))
        (define spaces
          (let ([p (skip-spaces text (token-end m) le)])
            (if (and (> p (token-end m)) (< p le)) (substring text (token-end m) p) " ")))
        (define-values (marker renumber)
          (cond
            [(eq? (token-role m) 'ordered-marker) (ordered-continuation text lst item m)]
            [else (values (token-text text m) '())]))
        (define prefix (line-prefix text m))
        (define blank (if (list-block-tight? lst) "" (string-append (string-trim prefix #:left? #f) "\n")))
        (define insert
          (string-append "\n" blank prefix marker spaces (if (item-task-pos text item) "[ ] " "")))
        (define edits (normalize-edits text (cons (edit c (+ c strip) insert) renumber)))
        (values edits (+ c (string-length insert)))])]))

;; The new item's marker after `item` in ordered list `lst`, and the edits renumbering the
;; items after it that would otherwise repeat or go backwards. A list numbered all alike
;; (`1.` everywhere) keeps that number and is left alone.
(define (ordered-continuation text lst item m)
  (define-values (n delim) (marker-number text m))
  (define siblings (list-block-children lst))
  (define numbers (for/list ([s (in-list siblings)]) (let-values ([(k d) (marker-number text (item-marker s))]) k)))
  (cond
    [(and (> (length siblings) 1) (for/and ([k (in-list numbers)]) (= k (car numbers))))
     (values (string-append (number->string n) delim) '())]
    [else
     (define after (cdr (memq item siblings)))
     (define renumber
       (let loop ([after after] [running (add1 n)] [acc '()])
         (cond
           [(null? after) (reverse acc)]
           [else
            (define sm (item-marker (car after)))
            (define-values (k d) (marker-number text sm))
            (if (<= k running)
                (loop (cdr after) (add1 running)
                      (cons (edit (token-start sm) (token-end sm) (string-append (number->string (add1 running)) d)) acc))
                (reverse acc))])))
     (values (string-append (number->string (add1 n)) delim) renumber)]))

;; ============================================================================================
;; Indent and outdent
;; ============================================================================================

(define (path-parents-for doc) (let-values ([(blocks parents) (blocks+parents doc)]) parents))

;; The items whose marker lines the selection touches, without those inside another of them
;; (moving an item moves its children).
(define (selected-items doc start end)
  (define text (document-text doc))
  (define-values (blocks parents) (blocks+parents doc))
  (define lines (selection-lines text start end))
  (define lo (first lines)) (define hi (line-end text (last lines)))
  (define items (filter (lambda (b) (and (list-item? b) (<= lo (token-start (item-marker b)) hi))) blocks))
  (define (has-selected-ancestor? b)
    (let loop ([p (hash-ref parents b #f)]) (and p (or (memq p items) (loop (hash-ref parents p #f))))))
  (values (filter (lambda (b) (not (has-selected-ancestor? b))) items) parents))

;; The lines of an item: its marker line through the line of its end.
(define (item-lines text item)
  (define m (item-marker item))
  (let loop ([ls (line-start text (token-start m))] [acc '()])
    (define le (line-end text ls))
    (if (or (>= le (block-end item)) (>= le (string-length text)))
        (reverse (cons ls acc))
        (loop (add1 le) (cons ls acc)))))

;; Moves the selected items one level in: each becomes the last child of its previous sibling,
;; its lines (children included) indented to that sibling's content column. A list's first
;; item has no sibling to go under and stays.
(define (indent-list-edits doc start end)
  (define text (document-text doc))
  (define-values (items parents) (selected-items doc start end))
  (normalize-edits
   text
   (append*
    (for/list ([item (in-list items)])
      (define lst (hash-ref parents item))
      (define prev (let loop ([ks (list-block-children lst)] [prev #f])
                     (cond [(null? ks) #f] [(eq? (car ks) item) prev] [else (loop (cdr ks) (car ks))])))
      (define m (item-marker item))
      (define marker-col (column-at text (line-start text (token-start m)) (token-start m)))
      (define k (if prev (- (list-item-content-indent prev) marker-col) 0))
      (if (<= k 0)
          '()
          (append
           ;; an ordered item joins the previous sibling's trailing ordered list, or starts one
           ;; at 1 (a nested list starting at 2 could not interrupt the sibling's paragraph)
           (if (eq? (token-role m) 'ordered-marker)
               (let* ([kids (list-item-children prev)]
                      [sub (and (pair? kids) (list-block? (last kids)) (list-block-ordered? (last kids)) (last kids))]
                      [n (if sub
                             (let-values ([(k d) (marker-number text (item-marker (last (list-block-children sub))))]) (add1 k))
                             1)])
                 (renumber-edit text m n))
               '())
           (for/list ([ls (in-list (item-lines text item))]
                      #:unless (blank-line? text ls (line-end text ls)))
             (define p (if (= ls (line-start text (token-start m)))
                           (token-start m)
                           (position-at-column text ls (line-end text ls) marker-col)))
             (edit p p (make-string k #\space)))))))))

;; The ordered marker `m` with number n, its delimiter kept.
(define (renumber-edit text m n)
  (define-values (k d) (marker-number text m))
  (list (edit (token-start m) (token-end m) (string-append (number->string n) d))))

;; Moves the selected items one level out, to their parent item's marker column. Top-level
;; items stay.
(define (outdent-list-edits doc start end)
  (define-values (items parents) (selected-items doc start end))
  (outdent-items (document-text doc) items (lambda (_) parents) doc))

(define (outdent-items text items parents-of doc)
  (define parents (parents-of doc))
  (normalize-edits
   text
   (append*
    (for/list ([item (in-list items)])
      (define outer (let loop ([p (hash-ref parents item #f)])
                      (cond [(not p) #f] [(list-item? p) p] [else (loop (hash-ref parents p #f))])))
      (cond
        [(not outer) '()]
        [else
         (define m (item-marker item))
         (define om (item-marker outer))
         (define target (column-at text (line-start text (token-start om)) (token-start om)))
         (define marker-col (column-at text (line-start text (token-start m)) (token-start m)))
         (define k (- marker-col target))
         (if (<= k 0)
             '()
             (append
              ;; an ordered item moving into its parent's ordered list takes the number after it
              (if (and (eq? (token-role m) 'ordered-marker) (eq? (token-role om) 'ordered-marker))
                  (let-values ([(n d) (marker-number text om)]) (renumber-edit text m (add1 n)))
                  '())
              (for/list ([ls (in-list (item-lines text item))]
                        #:unless (blank-line? text ls (line-end text ls)))
               (define le (line-end text ls))
               (define p (if (= ls (line-start text (token-start m)))
                             (let back ([p (token-start m)] [j 0])
                               (if (and (< j k) (> p ls) (eqv? (string-ref text (sub1 p)) #\space)) (back (sub1 p) (add1 j)) p))
                             (position-at-column text ls le target)))
               (define q (if (= ls (line-start text (token-start m)))
                             (token-start m)
                             (let fwd ([q p] [j 0])
                               (if (and (< j k) (< q le) (eqv? (string-ref text q) #\space)) (fwd (add1 q) (add1 j)) q))))
               (edit p q ""))))])))))

;; ============================================================================================
;; Task markers
;; ============================================================================================

(define (state-char state) (case state [(open) " "] [(done) "x"] [(cancelled) "-"]))

;; Sets the task state ('open 'done 'cancelled) of the list item at pos by rewriting the one
;; character between its brackets; an item without a task marker gets one. Outside list items,
;; no edits.
(define (set-task-edits doc pos state)
  (define text (document-text doc))
  (define item (item-at doc pos))
  (cond
    [(not item) '()]
    [(item-task-pos text item)
     => (lambda (tp) (normalize-edits text (list (edit (add1 tp) (+ tp 2) (state-char state)))))]
    [else
     (define m (item-marker item))
     (define p (item-content-pos text item))
     (normalize-edits text (list (edit p p (string-append (if (= p (token-end m)) " " "") "[" (state-char state) "] "))))]))

;; Toggles the task marker of the list item at pos: open becomes done, done (`[x]` or `[X]`) and
;; cancelled become open; an item without one becomes an open task.
(define (toggle-task-edits doc pos)
  (define text (document-text doc))
  (define item (item-at doc pos))
  (define tp (and item (item-task-pos text item)))
  (set-task-edits doc pos (if (and tp (eqv? (string-ref text (add1 tp)) #\space)) 'done 'open)))
