#lang racket/base
;; The Library index (#302 lib-index): what is extracted from a note (index-facts.rkt, pure), the
;; query API against a known fixture Library, incremental updates (correct, and under 100 ms),
;; a cold build of 5,000 notes under 30 s, corruption -> rebuild, and the app wiring (the worker
;; follows 'library-file-changed, 'after-save and the settings, and announces
;; 'library-index-changed).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list racket/string
         db/base db/sqlite3
         "timing.rkt"
         "../rackmac/library/index.rkt" "../rackmac/library/index-facts.rkt"
         "../rackmac/library/folders.rkt" "../rackmac/library/watch.rkt"
         "../rackmac/settings.rkt" "../rackmac/hook.rkt")

(define home (make-temporary-file "rackmac-index~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string home)))
(setting-set! 'library-folders '())

(define (p . parts) (path->string (apply build-path parts)))
(define (write! f s) (make-parent-directory* f) (display-to-file s f #:exists 'truncate))
(define (normalize x) (path->string (simplify-path (path->complete-path x))))   ; as the setting stores it

;; Handle GUI events until `pred` holds or `secs` pass.
(define (wait-until pred [secs (* ci-slack 5)])
  (define deadline (+ (current-inexact-milliseconds) (* 1000 secs)))
  (let loop ()
    (cond [(pred) #t]
          [(> (current-inexact-milliseconds) deadline) #f]
          [else (yield (alarm-evt (+ (current-inexact-milliseconds) 10))) (loop)])))

;; ---- extraction (pure) --------------------------------------------------------------------------

(define (facts text [path "/notes/a.md"]) (extract-note-facts text (string->path path) "a.md"))

(test-case "title: front matter title, else the first heading's text, else the file name"
  (check-equal? (note-facts-title (facts "---\ntitle: Engagement letter\n---\n# Heading\n")) "Engagement letter")
  (check-equal? (note-facts-title (facts "Intro line\n\n## **Second** level\n\n# First\n")) "Second level")
  (check-equal? (note-facts-title (facts "no heading at all\n")) "a.md")
  (check-equal? (note-facts-title (facts "#\n\n# Real\n")) "Real" "an empty heading is skipped")
  (check-equal? (note-facts-title (facts "# TODO Call the client\n")) "Call the client" "the state keyword is not title"))

(test-case "headings: every level, nested ones too, with offsets and 1-based lines"
  (check-equal? (map (lambda (h) (list (heading-fact-level h) (heading-fact-text h) (heading-fact-pos h) (heading-fact-line h)))
                     (note-facts-headings (facts "# One\n\ntext\n\n> ## Quoted\n")))
                '((1 "One" 0 1) (2 "Quoted" 15 5)) "a nested heading's span starts after the quote marker"))

(test-case "tags: inline and front matter, in headings, lists and tables; never inside code"
  (define f (facts "---\ntags: [Client, billing]\n---\n# Plan #Q3\n\nSee #acme/north and `#notatag`.\n\n```\n#nor-this\n```\n\n- item #work\n\n| a |\n|---|\n| #cell |\n"))
  (check-equal? (map tag-fact-name (note-facts-tags f)) '("Client" "billing" "Q3" "acme/north" "work" "cell"))
  (check-equal? (tag-fact-line (third (note-facts-tags f))) 4)
  (check-false (tag-fact-pos (first (note-facts-tags f))) "a front-matter tag has no position")
  (check-equal? (map tag-fact-name (note-facts-tags (facts "---\ntags: one, two #three\n---\n")))
                '("one" "two" "three") "a front-matter string splits on commas and spaces"))

(test-case "links: wiki (target, heading), relative file links resolved, URLs; images are not links"
  (define f (facts "A [[Other Note#Scope|the scope]] and [b](sub/b%20c.md#top), [up](../x.md), <https://example.com>, [m](mailto:a@b.c), ![pic](p.png)\n"
                   "/notes/dir/a.md"))
  (check-equal? (map (lambda (l) (list (link-fact-kind l) (link-fact-target l) (link-fact-heading l) (link-fact-resolved l)))
                     (note-facts-links f))
                '((wiki "Other Note" "Scope" #f)
                  (file "sub/b%20c.md#top" "top" "/notes/dir/sub/b c.md")
                  (file "../x.md" #f "/notes/x.md")
                  (url "https://example.com" #f #f)
                  (url "mailto:a@b.c" #f #f)))
  (check-equal? (link-fact-line (first (note-facts-links f))) 1)
  (check-true (string-prefix? (link-fact-context (first (note-facts-links f))) "A [[Other Note")))

(test-case "tasks: checkboxes (open, done, cancelled, nested) and heading keywords, with due dates"
  (define f (facts "# TODO Draft the brief due 2026-10-01\n\n- [ ] call **Ann** due 2026-09-30 #work\n  - [x] nested one\n- [-] dropped\n- plain item\n\n## DONE Filed\n\n## WAITING Reply\n"))
  (check-equal? (map (lambda (t) (list (task-fact-kind t) (task-fact-state t) (task-fact-keyword t) (task-fact-text t) (task-fact-due t) (task-fact-line t)))
                     (note-facts-tasks f))
                '((heading open "TODO" "Draft the brief due 2026-10-01" "2026-10-01" 1)
                  (checkbox open #f "call Ann due 2026-09-30 #work" "2026-09-30" 3)
                  (checkbox done #f "nested one" #f 4)
                  (checkbox cancelled #f "dropped" #f 5)
                  (heading done "DONE" "Filed" #f 8)
                  (heading open "WAITING" "Reply" #f 10))))

(test-case "tasks follow the heading keyword list passed in"
  (define f (extract-note-facts "# NEXT thing\n\n# FINISHED other\n\n# TODO x\n" (string->path "/n.md") "n.md"
                                #:heading-keywords '("NEXT" "FINISHED")))
  (check-equal? (map (lambda (t) (list (task-fact-keyword t) (task-fact-state t))) (note-facts-tasks f))
                '(("NEXT" open) ("FINISHED" done))))

(test-case "dates: every ISO date, with its keyword, line and context"
  (define f (facts "Hearing 2026-11-02.\n\n- [ ] file due 2026-10-15\n"))
  (check-equal? (map (lambda (d) (list (date-fact-date d) (date-fact-keyword d) (date-fact-line d) (date-fact-context d)))
                     (note-facts-dates f))
                '(("2026-11-02" #f 1 "Hearing 2026-11-02.") ("2026-10-15" "due" 3 "- [ ] file due 2026-10-15"))))

;; ---- a fixture Library and the query API ------------------------------------------------------------

(define lib (normalize (make-temporary-file "rackmac-lib~a" 'directory)))
(define acme (p lib "Clients" "Acme.md"))
(define plan (p lib "Plan.md"))
(define todo (p lib "Tasks" "todo.md"))
(define ambig1 (p lib "Minutes.md"))
(define ambig2 (p lib "Old" "Minutes.md"))
(define readme (p lib "readme.txt"))
(define script (p lib "tool.py"))
(write! acme "---\ntags: [client]\n---\n# Acme Corp\n\nMain client. #Litigation\n\n## Contacts\n\nSee [[Plan]] and [minutes](../Minutes.md).\n")
(write! plan "# Quarterly plan\n\nFor [[Acme Corp]] and [[acme]] (by file name) and [[acme corp#Contacts|contacts]].\nAlso [[Minutes]].\n\n- [ ] draft budget due 2026-10-01 #litigation\n- [x] kickoff 2026-09-01\n\n# TODO Hire due 2026-12-01\n")
(write! todo "# Todo\n\n- [ ] overdue thing due 2026-01-15\n- [ ] undated thing\n- [-] cancelled due 2026-02-01\n\nSee [the plan](../Plan.md#top).\n")
(write! ambig1 "# Minutes\n\nWeekly minutes mentioning zeppelin.\n")
(write! ambig2 "# Minutes\n\nOld minutes.\n")
(write! readme "plain text with the word zeppelin\n")
(write! script "print('hi')\n")
(write! (p lib ".hidden.md") "# Hidden\n")
(write! (p lib "node_modules" "x.md") "# Skipped\n")
(write! (p lib "scan.pdf") "not indexed")

(define db (build-path home "fixture.sqlite"))
(define idx (open-library-index db))
(define-values (built removed0) (library-index-reconcile! idx (list lib)))

;; Hidden files are the one difference: watch.rkt never reports them, so the index could not keep
;; them current, and leaves them out as the watcher does.
(test-case "the indexed files are the ones library-files lists, less hidden files"
  (setting-set! 'library-folders (list lib))
  (define listed (map path->string (library-files)))
  (setting-set! 'library-folders '())
  (check-not-false (member (p lib ".hidden.md") listed))
  (check-equal? (sort built string<?) (sort (remove (p lib ".hidden.md") listed) string<?))
  (check-equal? removed0 '())
  (check-true (library-index-ready? #:index idx)))

(test-case "notes: path, title, name; non-Markdown files by file name"
  (check-equal? (library-index-note acme #:index idx) (index-note acme "Acme Corp" "Acme.md"))
  (check-equal? (library-index-note readme #:index idx) (index-note readme "readme.txt" "readme.txt"))
  (check-false (library-index-note (p lib "scan.pdf") #:index idx))
  (check-equal? (map index-note-title (library-index-notes #:index idx))
                '("Acme Corp" "Minutes" "Minutes" "Quarterly plan" "readme.txt" "Todo" "tool.py")))

(test-case "headings of a note"
  (check-equal? (map (lambda (h) (list (index-heading-level h) (index-heading-text h) (index-heading-line h)))
                     (library-index-headings acme #:index idx))
                '((1 "Acme Corp" 4) (2 "Contacts" 8))))

(test-case "tags: per note, across the Library (case-insensitive), and notes carrying one"
  (check-equal? (library-index-note-tags acme #:index idx) '("client" "Litigation"))
  (check-equal? (map (lambda (t) (cons (string-downcase (car t)) (cdr t))) (library-index-all-tags #:index idx))
                '(("client" . 1) ("litigation" . 2)))
  (check-equal? (map index-note-path (library-index-notes-with-tag "LITIGATION" #:index idx)) (list acme plan))
  (check-equal? (map index-note-path (library-index-notes-with-tag "#client" #:index idx)) (list acme)))

(test-case "outgoing links of a note"
  (check-equal? (map (lambda (l) (list (index-link-kind l) (index-link-target l) (index-link-resolved l)))
                     (library-index-links acme #:index idx))
                (list (list 'wiki "Plan" #f) (list 'file "../Minutes.md" ambig1))))

(test-case "backlinks: Markdown links by path, wiki links by title or file name, any case; never self"
  (define to-acme (library-index-links-to acme #:index idx))
  (check-equal? (map (lambda (l) (list (index-link-path l) (index-link-target l) (index-link-heading l))) to-acme)
                (list (list plan "Acme Corp" #f) (list plan "acme" #f) (list plan "acme corp" "Contacts")))
  (check-equal? (index-link-line (first to-acme)) 3)
  (check-equal? (map index-link-path (library-index-links-to plan #:index idx)) (list acme todo)
                "[[Plan]] by file name, and a Markdown link with a #fragment"))

(test-case "wiki resolution: by title or file name; two matches is ambiguous"
  (check-equal? (map index-note-path (library-index-resolve-wiki "acme corp" #:index idx)) (list acme))
  (check-equal? (map index-note-path (library-index-resolve-wiki "Acme" #:index idx)) (list acme))
  (check-equal? (map index-note-path (library-index-resolve-wiki "Minutes" #:index idx)) (list ambig1 ambig2))
  (check-equal? (library-index-resolve-wiki "Nobody" #:index idx) '()))

(test-case "tasks: filters by state, due range, due or not, and path"
  (define (brief ts) (map (lambda (t) (list (index-task-text t) (index-task-state t) (index-task-due t))) ts))
  (check-equal? (brief (library-index-tasks #:state 'open #:due-to "2026-10-01" #:index idx))
                '(("overdue thing due 2026-01-15" open "2026-01-15") ("draft budget due 2026-10-01 #litigation" open "2026-10-01")))
  (check-equal? (brief (library-index-tasks #:state 'open #:due? #f #:index idx)) '(("undated thing" open #f)))
  (check-equal? (brief (library-index-tasks #:due-from "2026-11-01" #:index idx)) '(("Hire due 2026-12-01" open "2026-12-01")))
  (check-equal? (brief (library-index-tasks #:state '(done cancelled) #:index idx))
                '(("cancelled due 2026-02-01" cancelled "2026-02-01") ("kickoff 2026-09-01" done #f)))
  (check-equal? (length (library-index-tasks #:path todo #:index idx)) 3)
  (check-equal? (map index-task-kind (library-index-tasks #:path plan #:index idx)) '(checkbox heading checkbox)
                "by due date, undated last"))

(test-case "dates: range and keyword filters"
  (check-equal? (map index-date-date (library-index-dates #:from "2026-09-01" #:to "2026-10-31" #:index idx))
                '("2026-09-01" "2026-10-01"))
  (check-equal? (length (library-index-dates #:keyword "DUE" #:index idx)) 4)
  (check-equal? (index-date-context (first (library-index-dates #:path todo #:index idx))) "- [ ] overdue thing due 2026-01-15"))

(test-case "search: full text across kinds, words quoted so none is query syntax"
  (check-equal? (sort (map index-hit-path (library-index-search "zeppelin" #:index idx)) string<?) (sort (list ambig1 readme) string<?))
  (check-equal? (sort (map index-hit-path (library-index-search "zepp" #:index idx)) string<?) (sort (list ambig1 readme) string<?)
                "the last word matches as a prefix")
  (check-equal? (map index-hit-path (library-index-search "weekly zeppelin" #:index idx)) (list ambig1) "words combine with AND")
  (check-equal? (map index-hit-title (library-index-search "quarterly" #:index idx)) '("Quarterly plan") "titles are searched"))

(define (search-snippet q) (map index-hit-snippet (library-index-search q #:index idx #:open "«" #:close "»")))
(test-case "search snippets and hostile input"
  (check-true (for/or ([s (search-snippet "weekly zeppelin")]) (regexp-match? #rx"«zeppelin»" s)))
  (for ([q (list "\"" "AND" "a OR" "NEAR(" "-x" "*" "col:x" "")])
    (check-not-exn (lambda () (library-index-search q #:index idx)) q)))

;; ---- incremental ----------------------------------------------------------------------------------

(test-case "an edited note is re-indexed; an unchanged one is skipped; a removed one disappears"
  (write! todo "# Todo\n\n- [x] all done #finished\n")
  (check-true (library-index-update-file! idx todo))
  (check-false (library-index-update-file! idx todo) "same modify time and size: nothing to do")
  (check-equal? (library-index-note-tags todo #:index idx) '("finished"))
  (check-equal? (map index-link-path (library-index-links-to plan #:index idx)) (list acme) "its link to Plan is gone")
  (delete-file todo)
  (check-true (library-index-update-file! idx todo) "updating a vanished file removes it")
  (check-false (library-index-note todo #:index idx))
  (check-false (library-index-remove-file! idx todo) "already gone")
  (check-false (library-index-update-file! idx (p lib "scan.pdf")) "not an indexed kind"))

(test-case "a rename: removed old path, added new path, and backlinks by title still find it"
  (define renamed (p lib "Clients" "Acme Corporation.md"))
  (rename-file-or-directory acme renamed)
  (library-index-remove-file! idx acme)
  (library-index-update-file! idx renamed)
  (check-false (library-index-note acme #:index idx))
  (check-equal? (index-note-title (library-index-note renamed #:index idx)) "Acme Corp")
  (check-equal? (length (library-index-links-to renamed #:index idx)) 2 "[[Acme Corp]] twice by title; [[acme]] no longer matches")
  (rename-file-or-directory renamed acme)
  (library-index-reconcile! idx (list lib))
  (check-true (and (library-index-note acme #:index idx) #t))
  (check-false (library-index-note renamed #:index idx)))

(test-case "a reconcile drops files of a folder no longer in the Library, and of a missing folder"
  (define-values (changed removed) (library-index-reconcile! idx (list (p lib "Clients"))))
  (check-equal? changed '())
  (check-false (library-index-note plan #:index idx))
  (check-true (and (library-index-note acme #:index idx) #t))
  (library-index-reconcile! idx (list (p lib "no-such-folder")))
  (check-equal? (library-index-notes #:index idx) '())
  (library-index-reconcile! idx (list lib))
  (check-equal? (length (library-index-notes #:index idx)) 6))

(close-library-index idx)

;; ---- performance: 5,000 notes -------------------------------------------------------------------

(define big (normalize (make-temporary-file "rackmac-big~a" 'directory)))
(for ([i (in-range 5000)])
  (write! (p big (format "f~a" (quotient i 250)) (format "n~a.md" i))
          (format "# Note ~a\n\nCase ~a notes with #tag~a and [[Note ~a]].\n\n- [ ] follow up due 2026-10-~a\n- [x] done\n\n## Details\n\nA [link](../f0/n~a.md) on 2026-09-27.\n"
                  i i (modulo i 20) (modulo (add1 i) 5000) (+ 10 (modulo i 18)) (modulo i 250))))

(define big-idx (open-library-index (build-path home "big.sqlite")))

(test-case "a cold build of 5,000 notes takes under 30 s"
  (define t0 (current-inexact-milliseconds))
  (define-values (changed removed) (library-index-reconcile! big-idx (list big)))
  (define ms (- (current-inexact-milliseconds) t0))
  (printf "lib-index: cold build of 5,000 notes: ~a ms\n" (round ms))
  (check-equal? (length changed) 5000)
  (check-true (< ms (budget 30000)) (format "cold build took ~a ms" ms))
  (check-equal? (length (library-index-notes-with-tag "tag7" #:index big-idx)) 250))

(test-case "a startup pass over an unchanged Library re-reads nothing"
  (define t0 (current-inexact-milliseconds))
  (define-values (changed removed) (library-index-reconcile! big-idx (list big)))
  (printf "lib-index: unchanged reconcile of 5,000 notes: ~a ms\n" (round (- (current-inexact-milliseconds) t0)))
  (check-equal? (list changed removed) '(() ())))

(test-case "an incremental update takes under 100 ms, even in a 5,000-note index"
  (define f (p big "f3" "n777.md"))
  (define times
    (for/list ([k (in-range 10)])
      (write! f (format "# Edited ~a\n\n#fresh~a [[Note 1]] due 2026-10-0~a\n\n~a\n" k k (add1 (modulo k 9)) (make-string (* k 10) #\x)))
      (define t0 (current-inexact-milliseconds))
      (check-true (library-index-update-file! big-idx f))
      (- (current-inexact-milliseconds) t0)))
  (define worst (apply max times))
  (printf "lib-index: incremental update, median ~a ms, worst ~a ms\n"
          (/ (round (* 10 (list-ref (sort times <) 5))) 10) (/ (round (* 10 worst)) 10))
  (check-true (< worst (budget 100)) (format "worst update took ~a ms" worst))
  (check-equal? (library-index-note-tags f #:index big-idx) '("fresh9"))
  (define t0 (current-inexact-milliseconds))
  (library-index-remove-file! big-idx f)
  (check-true (< (- (current-inexact-milliseconds) t0) (budget 100)) "a removal too"))

(test-case "queries on 5,000 notes are fast enough for a panel"
  (define t0 (current-inexact-milliseconds))
  (library-index-links-to (p big "f0" "n7.md") #:index big-idx)
  (library-index-tasks #:state 'open #:due-to "2026-10-15" #:index big-idx)
  (library-index-search "case notes" #:index big-idx)
  (define ms (- (current-inexact-milliseconds) t0))
  (check-true (< ms (budget 200)) (format "three queries took ~a ms" ms)))

(close-library-index big-idx)
(delete-directory/files big)

;; ---- corruption -> rebuild ----------------------------------------------------------------------

(test-case "a garbage file is thrown away and rebuilt, never fatal"
  (define f (build-path home "garbage.sqlite"))
  (call-with-output-file f (lambda (o) (write-bytes (make-bytes 8192 65) o)) #:exists 'truncate)
  (define errors '())
  (define i (open-library-index f #:on-error (lambda (e) (set! errors (cons e errors)))))
  (check-true (library-index-was-reset? i))
  (check-false (library-index-in-memory? i))
  (check-pred pair? errors "the reason is reported")
  (library-index-reconcile! i (list lib))
  (check-equal? (length (library-index-notes #:index i)) 6)
  (close-library-index i)
  (define again (open-library-index f))
  (check-false (library-index-was-reset? again) "the rebuilt file opens cleanly")
  (check-equal? (length (library-index-notes #:index again)) 6)
  (close-library-index again))

(test-case "a truncated database (damaged pages) is rebuilt"
  (define f (build-path home "trunc.sqlite"))
  (define i (open-library-index f))
  (library-index-reconcile! i (list lib))
  (close-library-index i)
  (define bs (file->bytes f))
  (call-with-output-file f #:exists 'truncate
    (lambda (o) (write-bytes (subbytes bs 0 100) o) (write-bytes (make-bytes (- (bytes-length bs) 100) 7) o)))
  (define j (open-library-index f))
  (check-true (library-index-was-reset? j))
  (library-index-reconcile! j (list lib))
  (check-equal? (length (library-index-notes #:index j)) 6)
  (close-library-index j))

(test-case "a database from another schema version is rebuilt"
  (define f (build-path home "old.sqlite"))
  (define c (sqlite3-connect #:database f #:mode 'create))
  (query-exec c "CREATE TABLE files (path TEXT)")
  (query-exec c (format "PRAGMA user_version = ~a" (add1 library-index-schema-version)))
  (disconnect c)
  (define i (open-library-index f))
  (check-true (library-index-was-reset? i))
  (check-equal? (length (library-index-notes #:index i)) 0)
  (close-library-index i))

(test-case "a missing file is simply created (not a reset)"
  (define f (build-path home "sub" "dir" "new.sqlite"))
  (define i (open-library-index f))
  (check-false (library-index-was-reset? i))
  (check-true (file-exists? f))
  (close-library-index i))

(test-case "a database that cannot be made at all falls back to memory"
  (define blocker (build-path home "a-file"))
  (write! (path->string blocker) "x")
  (define i (open-library-index (build-path blocker "idx.sqlite")))   ; parent is a file
  (check-true (library-index-in-memory? i))
  (library-index-reconcile! i (list lib))
  (check-equal? (length (library-index-notes #:index i)) 6 "still answers for this session")
  (close-library-index i))

(test-case "queries with no index answer empty, never raise"
  (check-equal? (library-index-notes #:index #f) '())
  (check-false (library-index-note acme #:index #f))
  (check-equal? (library-index-search "x" #:index #f) '())
  (check-false (library-index-ready? #:index #f)))

;; ---- the app's index: worker, hooks, settings ---------------------------------------------------

(define announced '())
(define (on-index-changed paths) (set! announced (append announced paths)))
(add-hook! 'library-index-changed on-index-changed)

(define fake%
  (class object% (init-field path) (super-new) (define/public (get-path) path)))

(test-case "the app's index: startup pass, file events, saves, settings, and SQL damage while running"
  (setting-set! 'library-folders (list lib))
  (enable-library-index!)
  (check-true (library-index-wait!) "the worker answers")
  (check-true (library-index-ready?))
  (check-equal? (path->string (library-index-file-path)) (path->string (build-path home "library-index.sqlite")))
  (check-equal? (length (library-index-notes)) 6)
  (check-true (wait-until (lambda () (member plan announced))) "the startup pass is announced")

  ;; a watcher event
  (set! announced '())
  (define new-note (p lib "Clients" "New.md"))
  (write! new-note "# New client\n\n#intake\n")
  (run-hook 'library-file-changed 'added (string->path new-note) lib)
  (check-true (library-index-wait!))
  (check-equal? (library-index-note-tags new-note) '("intake"))
  (check-true (wait-until (lambda () (member new-note announced))) "announced on the GUI thread")
  ;; the same file reported again (nested Library folders) changes nothing
  (set! announced '())
  (run-hook 'library-file-changed 'modified (string->path new-note) (p lib "Clients"))
  (check-true (library-index-wait!))
  (yield (alarm-evt (+ (current-inexact-milliseconds) 50))) (yield)
  (check-equal? announced '())

  ;; a save by Rackmac
  (write! new-note "# New client\n\n#intake #urgent\n")
  (run-hook 'after-save (new fake% [path (string->path new-note)]))
  (check-true (library-index-wait!))
  (check-equal? (library-index-note-tags new-note) '("intake" "urgent"))
  ;; a save outside the Library is ignored
  (define outside (p home "elsewhere.md"))
  (write! outside "# Outside\n")
  (run-hook 'after-save (new fake% [path (string->path outside)]))
  (check-true (library-index-wait!))
  (check-false (library-index-note outside))

  ;; removal
  (delete-file new-note)
  (run-hook 'library-file-changed 'removed (string->path new-note) lib)
  (check-true (library-index-wait!))
  (check-false (library-index-note new-note))

  ;; the Library's folders change
  (setting-set! 'library-folders (list (p lib "Clients")))
  (check-true (library-index-wait!))
  (check-equal? (map index-note-path (library-index-notes)) (list acme))
  (setting-set! 'library-folders (list lib))
  (check-true (library-index-wait!))
  (check-equal? (length (library-index-notes)) 6)

  ;; the heading keywords change: headings are re-read
  (check-equal? (length (library-index-tasks #:path plan #:state 'open)) 2)
  (setting-set! 'heading-state-keywords "HIRE DONE")
  (check-true (library-index-wait!))
  (check-equal? (map index-task-keyword (library-index-tasks #:path plan)) '(#f #f)
                "TODO is no longer a keyword; the checkbox tasks remain")
  (setting-set! 'heading-state-keywords "TODO WAITING DONE")
  (check-true (library-index-wait!))

  ;; the database is damaged under the running worker: it starts over and rebuilds
  (define c (sqlite3-connect #:database (library-index-file-path)))
  (query-exec c "DROP TABLE tags")
  (disconnect c)
  (define errors '())
  (define old-reporter (error-reporter))
  (error-reporter (lambda (who e) (set! errors (cons e errors))))
  (write! plan "# Quarterly plan\n\n#rebuilt\n")
  (run-hook 'library-file-changed 'modified (string->path plan) lib)
  (check-true (library-index-wait!))
  (check-true (library-index-wait!) "the rebuild it queued has run too")
  (check-true (wait-until (lambda () (pair? errors))) "the damage was reported")
  (error-reporter old-reporter)
  (check-equal? (library-index-note-tags plan) '("rebuilt"))
  (check-equal? (library-index-note-tags acme) '("client" "Litigation") "every other note is back")

  (disable-library-index!)
  (check-false (current-library-index))
  (check-false (library-index-wait!) "no worker after disable"))

(test-case "end to end with the real watcher: a file added outside Rackmac reaches the index"
  (setting-set! 'library-folders (list lib))
  (enable-library-index!)
  (enable-library-watching!)
  (check-not-false (sync/timeout (* ci-slack 5) (library-watcher-ready-evt (library-watcher-for lib))))
  (check-true (library-index-wait!))
  (define f (p lib "Dropped in.md"))
  (write! f "# Dropped in\n\n#external\n")
  (check-true (wait-until (lambda () (library-index-wait!) (pair? (library-index-note-tags f))))
              "within the watcher's latency")
  (check-equal? (library-index-note-tags f) '("external"))
  (disable-library-watching!)
  (disable-library-index!))

(remove-hook! 'library-index-changed on-index-changed)
(setting-set! 'library-folders '())
(delete-directory/files lib)
