#lang racket/base
;; Live Library (#303 lib-watch): files added, renamed, deleted or rewritten from outside
;; Rackmac reach the 'library-file-changed hook and the Folders tree within 1 s; a watcher
;; stops -- thread dead, custodian shut down, descriptors closed -- when its folder leaves the
;; Library; the descriptor budget is kept and a folder past it (or missing) is still caught by
;; polling. Waits are bounded loops on a condition, never a fixed sleep, except where the test
;; is that nothing happens.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list racket/path
         "timing.rkt"
         "../rackmac/library/watch.rkt" "../rackmac/library/folders.rkt"
         "../rackmac/library/sidebar.rkt" "../rackmac/ui/sidebar.rkt"
         "../rackmac/settings.rkt" "../rackmac/frame.rkt" "../rackmac/hook.rkt")

(define dir (make-temporary-file "rackmac-watch~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())
(setting-set! 'show-library #t)
(setting-set! 'library-collapsed-sections '())

(define (p . parts) (apply build-path parts))
(define (write! f [s "# note\n"]) (display-to-file s f #:exists 'truncate))

;; Handle GUI events (where the hooks run) until `pred` holds or `secs` pass.
(define (wait-until pred [secs (* ci-slack 5)])
  (define deadline (+ (current-inexact-milliseconds) (* 1000 secs)))
  (let loop ()
    (cond
      [(pred) #t]
      [(> (current-inexact-milliseconds) deadline) #f]
      [else (yield (alarm-evt (+ (current-inexact-milliseconds) 10))) (loop)])))

;; Handle GUI events for a fixed time: only for proving that nothing arrives.
(define (settle secs) (wait-until (lambda () #f) secs))

(define events '())          ; (list kind path-string folder), oldest first
(define library-changes 0)
(define (on-file-changed kind path folder)
  (set! events (append events (list (list kind (path->string path) folder)))))
(define (on-library-changed) (set! library-changes (add1 library-changes)))
(add-hook! 'library-file-changed on-file-changed)
(add-hook! 'library-changed on-library-changed)
(define (reset!) (set! events '()) (set! library-changes 0))
(define (saw? kind path) (for/or ([e (in-list events)]) (and (eq? (car e) kind) (equal? (cadr e) (path->string path)))))

;; Open descriptors, where the OS lists them (macOS, Linux); elsewhere the counts are skipped.
(define fds-listed? (directory-exists? "/dev/fd"))
(define (nfds) (if fds-listed? (length (directory-list "/dev/fd")) 0))
(define-syntax-rule (check-fds e msg) (when fds-listed? (check-true e msg)))
(define (normalize x) (path->string (simplify-path (path->complete-path x))))   ; as the setting stores it

(define (ready! folder)
  (define w (library-watcher-for folder))
  (check-not-false w (format "a watcher runs for ~a" folder))
  (check-not-false (sync/timeout (* ci-slack 5) (library-watcher-ready-evt w)) "its first pass finished")
  w)

;; ---- one pass, as data ----------------------------------------------------------------------

(test-case "a pass records files and folders, skipping hidden entries and skip-listed folders, and not following folder links"
  (define root (make-temporary-file "rackmac-scan~a" 'directory))
  (make-directory* (p root "Clients" "Acme"))
  (make-directory* (p root "node_modules"))
  (make-directory* (p root ".git"))
  (write! (p root "a.md")) (write! (p root ".hidden.md")) (write! (p root "Clients" "Acme" "b.pdf"))
  (write! (p root "node_modules" "x.md")) (write! (p root ".git" "HEAD"))
  (define links? (not (eq? (system-type) 'windows)))   ; Windows links need a privilege
  (when links? (make-file-or-directory-link (p root "Clients") (p root "Loop")))
  (define before-list '())
  (define snap (scan-library-folder (path->string root)
                                    #:before-list (lambda (d) (set! before-list (cons (path->string d) before-list)))))
  (check-equal? (sort (hash-keys snap) string<?)
                (sort (map (lambda (x) (path->string (apply p root x)))
                           (append '(("a.md") ("Clients") ("Clients" "Acme") ("Clients" "Acme" "b.pdf"))
                                   (if links? '(("Loop")) '())))
                      string<?))
  (check-eq? (hash-ref snap (path->string (p root "Clients"))) 'dir)
  (check-pred pair? (hash-ref snap (path->string (p root "a.md"))) "a file's stamp is its modify time and size")
  (check-equal? (reverse before-list)
                (map path->string (list root (p root "Clients") (p root "Clients" "Acme")))
                "every directory walked is offered for watching before it is listed, breadth first; the link is not walked")
  (delete-directory/files root))

(test-case "a diff names added, removed and modified files in path order, and whether entries came or went"
  (define old (hash "/L/a.md" '(1 . 10) "/L/b.md" '(1 . 10) "/L/c.md" '(1 . 10) "/L/D" 'dir))
  (define-values (none structural0?) (diff-library-snapshots old (hash-copy old)))
  (check-equal? none '())
  (check-false structural0?)
  (define new (hash "/L/a.md" '(2 . 10) "/L/c.md" '(1 . 10) "/L/D" 'dir "/L/e.md" '(1 . 3)))
  (define-values (changes structural?) (diff-library-snapshots old new))
  (check-equal? changes '((modified . "/L/a.md") (removed . "/L/b.md") (added . "/L/e.md")))
  (check-true structural?)
  (define-values (only-mod s2?) (diff-library-snapshots old (hash-set old "/L/a.md" '(1 . 11))))
  (check-equal? only-mod '((modified . "/L/a.md")))
  (check-false s2? "a rewrite alone does not change the tree")
  (define-values (dirs-only s3?) (diff-library-snapshots old (hash-set old "/L/New" 'dir)))
  (check-equal? dirs-only '() "folders are not reported as files")
  (check-true s3? "but a new folder changes the tree"))

;; ---- watching a real folder ---------------------------------------------------------------

(define lib (p dir "Notes"))
(make-directory* (p lib "Clients"))
(write! (p lib "Agenda.md"))
(write! (p lib "Clients" "Engagement.md"))
(add-library-folder-path! lib)
(define lib-key (car (library-folder-paths)))
(define f (make-main-frame))     ; hidden: show is never called
(define (folder-labels)            ; the rows shown: Notes starts open, its subfolders closed
  (map bench-row-label (send (send (main-sidebar) get-folders-list) all-rows)))

(define fds-before-watching (nfds))
(enable-library-watching!)

(test-case "enabling starts one watcher per Library folder"
  (check-equal? (library-watched-folders) (list lib-key))
  (define w (ready! lib-key))
  (check-false (thread-dead? (library-watcher-thread w)))
  (check-equal? (library-watcher-armed-count w) 2 "Notes and Notes/Clients are each watched")
  (check-fds (>= (- (nfds) fds-before-watching) 2) "each watched directory holds a descriptor"))

(test-case "a file added from outside is reported within 1 s and shows in the Folders tree"
  (ready! lib-key)
  (reset!)
  (define new (p lib "Memo.md"))
  (define t0 (current-inexact-milliseconds))
  (write! new)
  (check-true (wait-until (lambda () (saw? 'added new))) "reported as added")
  (define took (- (current-inexact-milliseconds) t0))
  (check-true (< took (budget 1000)) (format "within 1 s (took ~a ms)" (round took)))
  (check-equal? (third (car events)) lib-key "the hook names the Library folder")
  (check-true (wait-until (lambda () (member "Memo.md" (folder-labels)))) "the Folders tree shows it")
  (check-true (>= library-changes 1)))

(test-case "a rename is the old path removed and the new one added; the tree follows"
  (reset!)
  (define old (p lib "Memo.md"))
  (define new (p lib "Memo 2.md"))
  (rename-file-or-directory old new)
  (check-true (wait-until (lambda () (and (saw? 'removed old) (saw? 'added new)))))
  (check-true (wait-until (lambda () (and (member "Memo 2.md" (folder-labels))
                                          (not (member "Memo.md" (folder-labels))))))))

(test-case "a delete is reported and the row leaves the tree"
  (reset!)
  (define gone (p lib "Memo 2.md"))
  (delete-file gone)
  (check-true (wait-until (lambda () (saw? 'removed gone))))
  (check-true (wait-until (lambda () (not (member "Memo 2.md" (folder-labels)))))))

(test-case "changes inside subfolders, including a folder created after watching began, are seen"
  (reset!)
  (define deep (p lib "Clients" "Brief.md"))
  (write! deep)
  (check-true (wait-until (lambda () (saw? 'added deep))) "an existing subfolder is watched")
  (define newdir (p lib "Matters"))
  (make-directory newdir)
  (check-true (wait-until (lambda () (>= library-changes 1))) "a new folder changes the tree")
  (check-true (wait-until (lambda () (member "Matters" (folder-labels)))))
  (reset!)
  (define inner (p newdir "Filing.md"))
  (write! inner)
  (check-true (wait-until (lambda () (saw? 'added inner))) "the new folder was armed on the next pass")
  (reset!)
  (delete-directory/files newdir)
  (check-true (wait-until (lambda () (saw? 'removed inner))) "removing a folder removes the files in it"))

(test-case "a burst of changes (a git checkout, a Finder copy) arrives as whole batches, nothing lost"
  (reset!)
  (define burst (for/list ([i 30]) (p lib "Clients" (format "b~a.md" i))))
  (for-each write! burst)
  (check-true (wait-until (lambda () (andmap (lambda (b) (saw? 'added b)) burst))))
  (reset!)
  (for-each delete-file burst)
  (check-true (wait-until (lambda () (andmap (lambda (b) (saw? 'removed b)) burst))))
  (check-equal? (length events) 30 "each file once"))

(test-case "hidden files (editor swap files, .DS_Store) are never reported"
  (reset!)
  (write! (p lib ".DS_Store"))
  (write! (p lib "Real.md"))
  (check-true (wait-until (lambda () (saw? 'added (p lib "Real.md")))))
  (check-false (saw? 'added (p lib ".DS_Store")))
  (delete-file (p lib ".DS_Store")))

(test-case "a file rewritten in place is 'modified on the rescan made when the window is activated, without a tree refresh"
  (reset!)
  (define target (p lib "Agenda.md"))
  (with-output-to-file target (lambda () (display "more text\n")) #:exists 'append)
  (run-hook 'window-activated)
  (check-true (wait-until (lambda () (saw? 'modified target))))
  (check-equal? (filter (lambda (e) (not (eq? (car e) 'modified))) events) '())
  (settle 0.3)
  (check-equal? library-changes 0 "only rewritten, so the tree need not change"))

;; ---- lifecycle ----------------------------------------------------------------------------

(test-case "removing a folder from the Library stops its watcher: thread dead, custodian shut down, descriptors closed, no more events"
  (define other (p dir "Other"))
  (make-directory* (p other "Sub"))
  (define fds-base (nfds))
  (add-library-folder-path! other)
  (define other-key (normalize other))
  (define w (ready! other-key))
  (check-equal? (library-watched-folders) (sort (list lib-key other-key) string<?))
  (check-fds (> (nfds) fds-base) "its directories are watched")
  (remove-library-folder-path! other)
  (check-equal? (library-watched-folders) (list lib-key) "only the remaining folder is watched")
  (check-false (library-watcher-for other-key))
  (check-true (thread-dead? (library-watcher-thread w)))
  (check-true (custodian-shut-down? (library-watcher-custodian w)))
  (check-fds (<= (nfds) fds-base) "every descriptor it held is closed")
  (reset!)
  (write! (p other "After.md"))
  (write! (p lib "Still.md"))
  (check-true (wait-until (lambda () (saw? 'added (p lib "Still.md")))) "the other watcher carries on")
  (settle 0.3)
  (check-false (saw? 'added (p other "After.md")) "the removed folder reports nothing"))

(test-case "a batch already on its way from a watcher that is then stopped is dropped"
  (define gone-dir (p dir "Brief"))
  (make-directory* gone-dir)
  (add-library-folder-path! gone-dir)
  (define key (normalize gone-dir))
  (ready! key)
  (reset!)
  (write! (p gone-dir "x.md"))
  ;; Give the watcher time to see it and queue the batch, but no GUI events run meanwhile.
  (sleep (+ (library-watch-debounce) 0.3))
  (remove-library-folder-path! gone-dir)
  (settle 0.2)
  (check-false (saw? 'added (p gone-dir "x.md"))))

(test-case "a Library folder that is missing is polled, and comes alive when it appears"
  (define later (p dir "Later"))
  (parameterize ([library-watch-poll-interval 0.2])
    (add-library-folder-path! later))
  (define key (normalize later))
  (define w (ready! key))
  (check-equal? (library-watcher-armed-count w) 0)
  (reset!)
  (make-directory later)
  (write! (p later "Found.md"))
  (check-true (wait-until (lambda () (saw? 'added (p later "Found.md")))) "picked up by polling")
  (check-true (wait-until (lambda () (> (library-watcher-armed-count w) 0))) "and then watched live")
  (reset!)
  (write! (p later "Live.md"))
  (check-true (wait-until (lambda () (saw? 'added (p later "Live.md")))))
  (remove-library-folder-path! later))

(test-case "the descriptor budget is split across folders; past it, deeper folders are polled"
  (define deep (p dir "Deep"))
  (make-directory* (p deep "a" "b" "c"))
  (define key (normalize deep))
  (parameterize ([library-watch-budget 4] [library-watch-poll-interval 0.2])
    (add-library-folder-path! deep)
    (define w (ready! key))
    (define w-lib (library-watcher-for lib-key))
    ;; Two folders share 4: each arms at most 2 (Notes re-arms with its new share).
    (check-true (wait-until (lambda () (<= (library-watcher-armed-count w-lib) 2))))
    (check-equal? (library-watcher-armed-count w) 2 "Deep and Deep/a, breadth first")
    (reset!)
    (define f (p deep "a" "b" "c" "Far.md"))
    (write! f)
    (check-true (wait-until (lambda () (saw? 'added f))) "an unwatched folder is still caught by polling")
    (remove-library-folder-path! deep))
  (sync-library-watches!)            ; back to the default budget for Notes
  (check-true (wait-until (lambda () (= (library-watcher-armed-count (library-watcher-for lib-key)) 2)))))

(test-case "disabling stops every watcher and follows the setting no more"
  (define ws (map library-watcher-for (library-watched-folders)))
  (disable-library-watching!)
  (check-equal? (library-watched-folders) '())
  (for ([w (in-list ws)])
    (check-true (thread-dead? (library-watcher-thread w)))
    (check-true (custodian-shut-down? (library-watcher-custodian w))))
  (check-fds (<= (nfds) fds-before-watching) "no descriptor is left open")
  (define again (p dir "Again"))
  (make-directory* again)
  (add-library-folder-path! again)
  (check-equal? (library-watched-folders) '() "a folder added while disabled is not watched")
  (remove-library-folder-path! again))

(remove-hook! 'library-file-changed on-file-changed)
(remove-hook! 'library-changed on-library-changed)
(send f show #f)
(delete-directory/files dir #:must-exist? #f)
