#lang racket/base
;; Live Library (#303 lib-watch; docs/REPLAN.md E16, docs/UI-DESIGN.md S2.1 "Refresh"): one
;; thread per Library folder notices files added, renamed, deleted or rewritten from outside
;; Rackmac (Finder, another app, a sync client, git) and tells the rest of the app through hooks:
;;
;;   'library-file-changed  (kind path folder)   once per changed file, in path order.
;;       kind is 'added, 'removed or 'modified; path is a complete path?; folder is the
;;       Library folder (a string, as `library-folder-paths` has it) the file lives under.
;;       A rename is 'removed for the old path, then 'added for the new one: the OS reports no
;;       pairing. Hidden (dot) files and folders, and `skip-library-dirs`, are never reported.
;;       This is what lib-index (#302) listens to. Two notes for it: a Library folder inside
;;       another is watched by both, so the same file can arrive twice with different
;;       `folder`s (key on the path); and Rackmac's own saves arrive here too, as 'modified
;;       (or 'added for a new file), besides the 'after-save hook.
;;   'library-changed       ()                   once per batch in which a file or folder
;;       appeared or disappeared (not for a file only rewritten). The sidebar's Folders tree
;;       already rescans on it (rackmac/library/sidebar.rkt), as after our own file actions.
;;
;; Both run on the eventspace that called `sync-library-watches!` (the GUI thread), never on
;; a watcher thread, so listeners may touch the window and the registries.
;;
;; How it watches. `filesystem-change-evt` on macOS (kqueue) is one-shot, per directory and not
;; recursive, holds one file descriptor while armed, and sees entries added, renamed or removed
;; but not a file rewritten in place. So each pass arms one evt per directory -- before listing
;; that directory, so a change made while the pass runs still fires -- records every entry's
;; modify time and size, and diffs against the previous pass. After an evt fires the thread
;; waits `library-watch-debounce` (a git checkout or a Finder copy is a burst), cancels every
;; evt and makes a fresh pass. In-place rewrites are caught by the rescan each watcher makes
;; when the window is activated (the "fallback rescan on activate" of docs/REPLAN.md).
;;
;; File descriptors are budgeted. A Mac app started from the Finder gets a soft limit of 256
;; open files (`launchctl limit maxfiles`) and Racket does not raise it; running out breaks
;; everything, even loading a module. All watchers together arm at most `library-watch-budget`
;; directories, split evenly, breadth first (top-level folders stay live). A watcher that could
;; not arm every directory, or whose folder is missing (an unmounted drive), rescans every
;; `library-watch-poll-interval` seconds instead, so it still converges and notices the folder
;; coming back.
;;
;; Lifecycle. This is core plumbing tied to the `library-folders` setting, not something an
;; extension registers, so it follows that setting instead of `register-undo!`: each watcher
;; runs in its own custodian (thread and evts alike); `sync-library-watches!` starts one per
;; folder and stops the watchers of folders no longer in the Library (Remove Folder…); stopping
;; asks the thread to finish, then shuts the custodian down, which kills the thread and closes
;; its descriptors whatever state it was in. A batch already queued for the GUI thread from a
;; stopped watcher is dropped. `enable-library-watching!` (app startup) follows the setting and
;; window activation and stops everything at exit; `disable-library-watching!` undoes it.
;; The manager functions are called from the GUI thread only.
(require racket/list racket/gui/base
         "../hook.rkt" "folders.rkt")
(provide enable-library-watching! disable-library-watching!
         sync-library-watches! stop-all-library-watches! rescan-library-watches!
         library-watched-folders library-watcher-for
         library-watcher? library-watcher-folder library-watcher-thread library-watcher-custodian
         library-watcher-armed-count library-watcher-ready-evt
         library-watch-budget library-watch-debounce library-watch-poll-interval
         scan-library-folder diff-library-snapshots)

(define library-watch-budget (make-parameter 128))        ; directories armed, all watchers together
(define library-watch-debounce (make-parameter 0.1))      ; seconds
(define library-watch-poll-interval (make-parameter 5))   ; seconds, only when not fully armed

;; ---- one pass over a folder ---------------------------------------------------------------

(define (hidden-name? n) (regexp-match? #rx"^[.]" n))

;; A file's stamp: its modify time and size, or #f if it vanished while we looked.
(define (file-stamp p)
  (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
    (define st (file-or-directory-stat p))
    (cons (hash-ref st 'modify-time-nanoseconds) (hash-ref st 'size))))

;; Breadth first from `root`: calls (before-list dir) for each directory just before listing
;; it, and returns a snapshot, a hash from path string to 'dir or a file stamp. An unreadable
;; directory has no entries. Symbolic links to directories are listed but not followed, so a
;; link cycle cannot make the walk endless.
(define (scan-library-folder root #:before-list [before-list void])
  (define snap (make-hash))
  (let loop ([queue (list (if (path? root) root (string->path root)))])
    (cond
      [(null? queue) snap]
      [else
       (define dir (car queue))
       (before-list dir)
       (define names (with-handlers ([exn:fail:filesystem? (lambda (x) '())]) (directory-list dir)))
       (define subdirs
         (for*/fold ([acc '()] #:result (reverse acc))
                    ([n (in-list names)]
                     #:unless (hidden-name? (path->string n)))
           (define p (build-path dir n))
           (define key (path->string p))
           (cond
             [(directory-exists? p)
              (cond
                [(member (path->string n) skip-library-dirs) acc]
                [else (hash-set! snap key 'dir)
                      (if (link-exists? p) acc (cons p acc))])]
             [(file-exists? p)
              (define st (file-stamp p))
              (when st (hash-set! snap key st))
              acc]
             [else acc])))
       (loop (append (cdr queue) subdirs))])))

;; The files that were added, removed or modified between two snapshots, as a list of
;; (cons kind path-string) sorted by path, and whether any entry (file or folder) appeared or
;; disappeared.
(define (diff-library-snapshots old new)
  (define (file? v) (and v (not (eq? v 'dir))))
  (define changes
    (append
     (for/list ([(k v) (in-hash new)]
                #:when (file? v)
                #:unless (file? (hash-ref old k #f)))
       (cons 'added k))
     (for/list ([(k v) (in-hash old)]
                #:when (file? v)
                #:unless (file? (hash-ref new k #f)))
       (cons 'removed k))
     (for/list ([(k v) (in-hash new)]
                #:when (file? v)
                #:when (let ([o (hash-ref old k #f)]) (and (file? o) (not (equal? o v)))))
       (cons 'modified k))))
  (define structural?
    (or (for/or ([k (in-hash-keys new)]) (not (hash-has-key? old k)))
        (for/or ([k (in-hash-keys old)]) (not (hash-has-key? new k)))
        (for/or ([(k v) (in-hash new)]) (not (eq? (eq? v 'dir) (eq? (hash-ref old k #f) 'dir))))))
  (values (sort changes string<? #:key cdr) structural?))

;; ---- a watcher ------------------------------------------------------------------------------

(struct library-watcher (folder custodian [thread #:mutable] share armed ready [live? #:mutable]))
;; share: a box, the number of directories this watcher may arm (set by the manager).
;; armed: a box, how many it armed on its last pass (for tests and diagnostics).
;; ready: a semaphore posted once the first pass is done (changes before that are the baseline).

(define (library-watcher-armed-count w) (unbox (library-watcher-armed w)))
(define (library-watcher-ready-evt w) (semaphore-peek-evt (library-watcher-ready w)))

;; Runs in the watcher's thread, under its custodian. `deliver` runs a thunk on the GUI thread.
(define (watch-loop w deliver debounce poll-interval)
  (define root (library-watcher-folder w))
  (define (on-gui-thread-while-live proc)
    (deliver (lambda () (when (library-watcher-live? w) (proc)))))
  (let loop ([prev #f])
    (define allowed (unbox (library-watcher-share w)))
    (define evts '())            ; every evt armed this pass, so all of them are cancelled below
    (define first-dir? #t)
    (define root-armed? #f)
    (define out-of-budget? #f)
    (define (arm! dir)
      (cond
        [(>= (length evts) allowed) (set! out-of-budget? #t)]
        [else
         (define e (filesystem-change-evt dir (lambda () #f)))   ; #f: vanished, unreadable, no fds
         (when e (set! evts (cons e evts)))
         (when first-dir? (set! root-armed? (and e #t)))])
      (set! first-dir? #f))
    (define snap
      (with-handlers ([exn:fail? (lambda (e)
                                   (on-gui-thread-while-live (lambda () (report-error! 'library-watch e)))
                                   (set! root-armed? #f)          ; poll until a pass succeeds
                                   #f)])
        (scan-library-folder root #:before-list arm!)))
    (set-box! (library-watcher-armed w) (length evts))
    (cond
      [(not snap) (void)]
      [(not prev) (semaphore-post (library-watcher-ready w))]   ; the first pass is the baseline
      [else
       (define-values (changes structural?) (diff-library-snapshots prev snap))
       (when (or structural? (pair? changes))
         (on-gui-thread-while-live
          (lambda ()
            (for ([c (in-list changes)])
              (run-hook 'library-file-changed (car c) (string->path (cdr c)) root))
            (when structural? (run-hook 'library-changed)))))])
    (define msg
      (sync (if (null? evts) never-evt (handle-evt (apply choice-evt evts) (lambda (_) 'changed)))
            (handle-evt (thread-receive-evt) (lambda (_) (thread-receive)))
            (if (or out-of-budget? (not root-armed?))
                (handle-evt (alarm-evt (+ (current-inexact-milliseconds) (* 1000 poll-interval)))
                            (lambda (_) 'poll))
                never-evt)))
    (when (eq? msg 'changed) (sleep debounce))
    (for-each filesystem-change-evt-cancel evts)
    (unless (eq? msg 'stop) (loop (or snap prev)))))

;; Thunks run on the eventspace that started the watcher.
(define ((make-deliver es) thunk)
  (parameterize ([current-eventspace es])
    (queue-callback thunk)))

(define (start-watcher folder share)
  (define c (make-custodian))
  (define w (library-watcher folder c #f (box share) (box 0) (make-semaphore 0) #t))
  (define deliver (make-deliver (current-eventspace)))
  (define debounce (library-watch-debounce))
  (define poll (library-watch-poll-interval))
  (set-library-watcher-thread!
   w (parameterize ([current-custodian c])
       (thread (lambda () (watch-loop w deliver debounce poll)))))
  w)

;; Ask the thread to finish (it is almost always waiting in `sync`, so it does at once), then
;; shut its custodian down regardless: that kills the thread if it is still busy and closes
;; every descriptor it armed.
(define (stop-watcher w)
  (set-library-watcher-live?! w #f)
  (define t (library-watcher-thread w))
  (thread-send t 'stop #f)
  (sync/timeout 0.25 t)
  (custodian-shutdown-all (library-watcher-custodian w)))

;; ---- the manager (GUI thread only) ---------------------------------------------------------

(define watchers (make-hash))   ; Library folder string -> library-watcher

(define (library-watched-folders) (sort (hash-keys watchers) string<?))
(define (library-watcher-for folder) (hash-ref watchers folder #f))

;; One watcher per folder in the Library, no more: removed folders' watchers stop, new folders
;; get one, and the descriptor budget is split again (a watcher whose share changed re-arms).
;; Removals happen first, so their descriptors are free before new ones are armed.
(define (sync-library-watches!)
  (define want (remove-duplicates (library-folder-paths)))
  (for ([k (in-list (hash-keys watchers))] #:unless (member k want))
    (stop-watcher (hash-ref watchers k))
    (hash-remove! watchers k))
  (define share (quotient (library-watch-budget) (max 1 (length want))))
  (for ([w (in-hash-values watchers)] #:unless (= share (unbox (library-watcher-share w))))
    (set-box! (library-watcher-share w) share)
    (thread-send (library-watcher-thread w) 'rescan #f))
  (for ([k (in-list want)] #:unless (hash-ref watchers k #f))
    (hash-set! watchers k (start-watcher k share))))

(define (stop-all-library-watches!)
  (for ([w (in-hash-values watchers)]) (stop-watcher w))
  (hash-clear! watchers))

;; A fresh pass by every watcher now: catches files rewritten in place, which the OS does not
;; report for a directory.
(define (rescan-library-watches!)
  (for ([w (in-hash-values watchers)]) (thread-send (library-watcher-thread w) 'rescan #f)))

;; ---- wiring ---------------------------------------------------------------------------------

(define (on-setting-changed name) (when (eq? name 'library-folders) (sync-library-watches!)))
(define (on-window-activated) (rescan-library-watches!))
(define exit-flush #f)

(define (enable-library-watching!)
  (add-hook! 'setting-changed on-setting-changed)
  (add-hook! 'window-activated on-window-activated)
  (unless exit-flush
    (set! exit-flush (plumber-add-flush! (current-plumber) (lambda (h) (stop-all-library-watches!)))))
  (sync-library-watches!))

(define (disable-library-watching!)
  (remove-hook! 'setting-changed on-setting-changed)
  (remove-hook! 'window-activated on-window-activated)
  (when exit-flush (plumber-flush-handle-remove! exit-flush) (set! exit-flush #f))
  (stop-all-library-watches!))
