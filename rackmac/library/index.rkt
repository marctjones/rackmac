#lang racket/base
;; The Library index (#302 lib-index; docs/REPLAN.md E16.M1): a SQLite database (Racket's `db`
;; library over the system libsqlite3, both in the standard distribution) holding, for every
;; Library file, its path, title, headings, tags, links, tasks and dates, plus its full text for
;; FTS5 search. It is what wiki links (#304), the Backlinks panel (#305), Search Library (#306),
;; task dates (#295), tags (#296) and Today (#297) query; none of them needs to know SQL.
;;
;; ---- Query API ---------------------------------------------------------------------------------
;; Every query reads the committed index and has no other effect. Each takes `#:index` (default:
;; the app's index, `(current-library-index)`), and answers '() or #f -- never raises -- when no
;; index is open or it is being rebuilt. Paths go in as path-strings and come out as strings:
;; complete, `simplify-path`ed paths, exactly the keys watch.rkt reports (a file's path built
;; under its Library folder as the `library-folders` setting stores it; symbolic links are not
;; resolved). Dates are "YYYY-MM-DD" strings (so they compare with string<?). `pos` is the
;; 0-based offset into the note's text (a text% position once it is open), `line` is 1-based,
;; `context` is that whole source line.
;;
;;   (library-index-note path)            -> (or/c index-note? #f)      ; path, title, name
;;   (library-index-notes)                -> (listof index-note?)        ; every file, by title
;;   (library-index-headings path)        -> (listof index-heading?)     ; path level text pos line
;;   (library-index-note-tags path)       -> (listof string?)            ; distinct (any case), in order
;;   (library-index-all-tags)             -> (listof (cons/c string? exact-nonnegative-integer?))
;;                                           ; each tag and how many notes carry it, by name
;;   (library-index-notes-with-tag tag)   -> (listof index-note?)        ; case-insensitive, no "#"
;;   (library-index-links path)           -> (listof index-link?)        ; the note's outgoing links
;;   (library-index-links-to path)        -> (listof index-link?)        ; backlinks: links in OTHER
;;       notes that reach `path` -- a Markdown link whose resolved path is it, or a [[wiki link]]
;;       whose target equals its title, file name or file name without extension (any case).
;;       Each index-link's `path` is the linking note.
;;   (library-index-resolve-wiki target)  -> (listof index-note?)        ; notes a [[target]] names
;;       (same matching; more than one = ambiguous, #304 asks). Titles are matched at query
;;       time, never stored resolved, because a title changes when its note is edited.
;;   (library-index-tasks #:path #:state #:due-from #:due-to #:due?)
;;                                        -> (listof index-task?)        ; path kind state keyword
;;       text due pos line. kind 'checkbox or 'heading; state 'open 'done 'cancelled. Filters are
;;       optional and combine: #:state a state or a list of them; #:due-from/#:due-to inclusive
;;       (either implies a due date); #:due? #t only tasks with a due date, #f only without.
;;       Ordered by due date (undated last), then path, then position. "Due on or before Z" is
;;       #:due-to Z; "overdue" is #:state 'open #:due-to <yesterday>.
;;   (library-index-dates #:path #:from #:to #:keyword)
;;                                        -> (listof index-date?)        ; path date keyword pos
;;       line context: every ISO date written in a note, by date then path.
;;   (library-index-search text #:limit #:open #:close)
;;                                        -> (listof index-hit?)         ; path title snippet
;;       full-text search, best first; `text` is plain words (never FTS syntax: each word is
;;       quoted, the last one matches as a prefix); the snippet (one line) marks matches with
;;       #:open/#:close (default "[" "]").
;;   (library-index-ready?)               -> boolean?                    ; the first pass is done
;;
;; index-link: path kind target heading resolved pos line context. kind 'wiki, 'file (a Markdown
;; link to a relative path; `resolved` is the complete path it names) or 'url. See
;; rackmac/library/index-facts.rkt for exactly what is extracted and how (the pure half of this).
;;
;; Hook: 'library-index-changed (paths) runs on the GUI thread after the index changed, with the
;; path strings whose rows were written or removed -- a Backlinks panel or Today view refreshes
;; on it ("live after save"). A startup pass or rebuild reports every path it touched.
;;
;; ---- How it stays current ----------------------------------------------------------------------
;; One worker thread owns every write (a separate read connection serves the queries: in WAL mode
;; it sees only committed data, never a half-written file or a rebuild in progress). Messages:
;;   * startup, and 'setting-changed 'library-folders: a *reconcile* -- walk every Library folder
;;     with watch.rkt's `scan-library-folder`, compare each file's modify time and size with the
;;     stored ones, re-read only what changed, drop rows for files no longer in any Library
;;     folder. A cold build is a reconcile against an empty database. watch.rkt's first pass is
;;     a silent baseline, so this pass is what catches changes made while Rackmac was closed.
;;   * 'library-file-changed (kind path folder): 'added/'modified re-index that one file,
;;     'removed drops it (one transaction each; under 100 ms). Keyed on the path, so a file
;;     reported twice (a Library folder nested in another is watched by both) is written twice,
;;     harmlessly -- the second time is skipped because its modify time is already stored.
;;   * 'after-save: Rackmac's own saves also arrive as 'modified above; indexing on save too
;;     makes backlinks live without waiting for the watcher's debounce. Same idempotence.
;;   * 'library-changed carries no paths, and every file it covers already had its own
;;     'library-file-changed, so the index ignores it (a rescan per batch would be wasted work).
;;   * 'setting-changed 'heading-state-keywords: every note is re-read, since which headings are
;;     tasks depends on that list.
;; A folder that disappears (an unmounted drive) reads as empty: its rows go, as watch.rkt reports
;; its files 'removed, and come back when it does. Indexed files are the kinds `library-files`
;; lists (.md .markdown .txt .rkt .py); only Markdown is parsed, the rest are title (file name)
;; and full text. A file over `library-index-max-bytes` is indexed by name only.
;;
;; ---- Where, and when it breaks -----------------------------------------------------------------
;; The database is <config dir>/library-index.sqlite (platform.rkt's `config-dir`, beside
;; settings.rktd and recovery/: never inside a Library folder, which a sync client would copy).
;; It is only a cache of the notes. On open it must pass `PRAGMA quick_check` and carry this
;; module's `library-index-schema-version`; if it is unreadable, corrupt, or from another
;; version, it (and its -wal/-shm/-journal files) is deleted and rebuilt from the notes. A SQL
;; error while writing does the same, once: if the job right after that rebuild fails too, the
;; index closes for the session (queries answer empty) instead of rebuilding in a loop. Errors
;; on the read side are not detected: a query that fails answers empty. If even a fresh file cannot be made, the index lives in
;; memory for this session and the error goes to Activity.
;;
;; Lifecycle mirrors watch.rkt: core plumbing tied to settings, not an extension, so no
;; `register-undo!`. `enable-library-index!` (app startup) opens it, adds the hooks and starts
;; the first pass; `disable-library-index!` (also run at exit) stops the worker and closes it.
(require racket/list racket/string racket/path racket/file racket/class racket/gui/base
         db/base db/sqlite3
         "../hook.rkt" "../platform.rkt" "../fileio.rkt" "../md-heading-state.rkt"
         "folders.rkt" "watch.rkt" "index-facts.rkt")
(provide (struct-out index-note) (struct-out index-heading) (struct-out index-link)
         (struct-out index-task) (struct-out index-date) (struct-out index-hit)
         library-index-note library-index-notes library-index-headings
         library-index-note-tags library-index-all-tags library-index-notes-with-tag
         library-index-links library-index-links-to library-index-resolve-wiki
         library-index-tasks library-index-dates library-index-search library-index-ready?
         ;; the app's index
         enable-library-index! disable-library-index! current-library-index library-index-wait!
         ;; lower level, synchronous (the worker, and tests)
         library-index? open-library-index close-library-index library-index-file-path
         library-index-was-reset? library-index-in-memory?
         library-index-reconcile! library-index-rebuild! library-index-update-file!
         library-index-remove-file! library-index-indexed-path?
         library-index-schema-version library-index-max-bytes)

(define library-index-schema-version 1)
(define library-index-max-bytes (make-parameter (* 4 1024 1024)))
(define batch-size 250)                     ; files per transaction in a reconcile

(define (library-index-file-path) (build-path (config-dir) "library-index.sqlite"))

;; ---- results -----------------------------------------------------------------------------------

(struct index-note (path title name) #:transparent)
(struct index-heading (path level text pos line) #:transparent)
(struct index-link (path kind target heading resolved pos line context) #:transparent)
(struct index-task (path kind state keyword text due pos line) #:transparent)
(struct index-date (path date keyword pos line context) #:transparent)
(struct index-hit (path title snippet) #:transparent)

;; ---- the database ------------------------------------------------------------------------------

;; file: a path or 'memory. writer: the connection the worker writes through; reader: the one
;; queries use (the same connection in memory, where a second one would be another database).
;; stmts: prepared writer statements. reset?: this open found a bad file and started over.
;; built?: a whole reconcile has finished at least once.
(struct library-index ([file #:mutable] [writer #:mutable] [reader #:mutable] [stmts #:mutable] [fts? #:mutable]
                       [reset? #:mutable] [built? #:mutable])
  #:constructor-name make-library-index)
(define (library-index-was-reset? idx) (library-index-reset? idx))
(define (library-index-in-memory? idx) (eq? (library-index-file idx) 'memory))

(define schema
  '("CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
       stem TEXT NOT NULL COLLATE NOCASE, title TEXT NOT NULL COLLATE NOCASE,
       mtime INTEGER NOT NULL, size INTEGER NOT NULL)"
    "CREATE INDEX files_title ON files(title)"
    "CREATE INDEX files_stem ON files(stem)"
    "CREATE INDEX files_name ON files(name COLLATE NOCASE)"
    "CREATE TABLE headings (file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       level INTEGER, text TEXT, pos INTEGER, line INTEGER)"
    "CREATE TABLE tags (file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       tag TEXT NOT NULL COLLATE NOCASE, pos INTEGER, line INTEGER)"
    "CREATE TABLE links (file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       kind TEXT NOT NULL, target TEXT COLLATE NOCASE, heading TEXT, resolved TEXT,
       pos INTEGER, line INTEGER, context TEXT)"
    "CREATE TABLE tasks (file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       kind TEXT NOT NULL, state TEXT NOT NULL, keyword TEXT, text TEXT, due TEXT,
       pos INTEGER, line INTEGER)"
    "CREATE TABLE dates (file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       date TEXT NOT NULL, keyword TEXT, pos INTEGER, line INTEGER, context TEXT)"
    "CREATE INDEX headings_file ON headings(file_id)"
    "CREATE INDEX tags_file ON tags(file_id)"
    "CREATE INDEX tags_tag ON tags(tag)"
    "CREATE INDEX links_file ON links(file_id)"
    "CREATE INDEX links_resolved ON links(resolved)"
    "CREATE INDEX links_target ON links(target)"
    "CREATE INDEX tasks_file ON tasks(file_id)"
    "CREATE INDEX tasks_due ON tasks(due)"
    "CREATE INDEX dates_file ON dates(file_id)"
    "CREATE INDEX dates_date ON dates(date)"))

(define fts-schema
  "CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2')")

(define (table-exists? c name)
  (and (query-maybe-value c "SELECT 1 FROM sqlite_master WHERE name = ?" name) #t))

(define (setup-connection! c)
  (query-value c "PRAGMA journal_mode = WAL")         ; returns a row, so query-value
  (query-exec c "PRAGMA synchronous = NORMAL")
  (query-exec c "PRAGMA foreign_keys = ON"))

;; A checked writer connection: passes quick_check and carries our schema, creating the schema
;; in an empty database. Raises on anything else.
(define (connect-checked file)
  (define c (sqlite3-connect #:database file #:mode 'create #:busy-retry-limit 50))
  (with-handlers ([(lambda (e) #t) (lambda (e) (disconnect c) (raise e))])
    (define check (query-value c "PRAGMA quick_check"))
    (unless (equal? check "ok") (error 'library-index "integrity check failed: ~a" check))
    (setup-connection! c)
    (define version (query-value c "PRAGMA user_version"))
    (cond
      [(= version library-index-schema-version)
       (unless (table-exists? c "files") (error 'library-index "tables missing"))]
      [(and (= version 0) (not (query-maybe-value c "SELECT 1 FROM sqlite_master LIMIT 1")))
       (call-with-transaction c
         (lambda ()
           (for ([s (in-list schema)]) (query-exec c s))
           ;; FTS5 is in macOS's libsqlite3 (verified on 3.51); without it, search falls back
           (with-handlers ([exn:fail:sql? void]) (query-exec c fts-schema))
           (query-exec c (format "PRAGMA user_version = ~a" library-index-schema-version))))]
      [else (error 'library-index "schema version ~a, this Rackmac uses ~a" version library-index-schema-version)])
    c))

(define (delete-index-files! file)
  (for ([suffix (in-list '("" "-wal" "-shm" "-journal"))])
    (define p (string-append (path->string file) suffix))
    (when (file-exists? p) (delete-file p))))

;; Opens (or makes) the index at `file`; a bad file is deleted and started afresh (see header).
;; `on-error` hears about anything that had to be thrown away.
(define (open-library-index [file (library-index-file-path)] #:on-error [on-error (lambda (e) (void))])
  (define idx (make-library-index file #f #f #f #f #f #f))
  (connect! idx on-error)
  idx)

(define (connect! idx on-error)
  (define file (library-index-file idx))
  (define (open-at f)
    (define w (connect-checked f))
    (define r (if (eq? f 'memory) w
                  (sqlite3-connect #:database f #:mode 'read-only #:busy-retry-limit 50)))
    (values w r))
  (define-values (w r)
    (cond
      [(eq? file 'memory) (open-at 'memory)]
      [else
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (on-error e)
                          (set-library-index-reset?! idx #t)
                          (with-handlers ([exn:fail? (lambda (e2)
                                                       (on-error e2)
                                                       (set! file 'memory)
                                                       (open-at 'memory))])
                            (delete-index-files! file)
                            (open-at file)))])
         (make-parent-directory* file)
         (open-at file))]))
  (set-library-index-file! idx file)      ; 'memory if even a fresh file could not be made
  (set-library-index-writer! idx w)
  (set-library-index-reader! idx r)
  (set-library-index-stmts! idx (make-hasheq))
  (set-library-index-fts?! idx (table-exists? w "fts")))

(define (close-library-index idx)
  (define w (library-index-writer idx))
  (define r (library-index-reader idx))
  (when (and r (not (eq? r w))) (with-handlers ([exn:fail? void]) (disconnect r)))
  (when w (with-handlers ([exn:fail? void]) (disconnect w)))
  (set-library-index-writer! idx #f)
  (set-library-index-reader! idx #f))

;; A SQL error while writing: throw the file away and start over (the caller then reconciles).
(define (reset-library-index! idx on-error)
  (close-library-index idx)
  (unless (eq? (library-index-file idx) 'memory)
    (with-handlers ([exn:fail? on-error]) (delete-index-files! (library-index-file idx))))
  (set-library-index-built?! idx #f)
  (connect! idx on-error)
  (set-library-index-reset?! idx #t))

;; ---- writing -----------------------------------------------------------------------------------

(define statements
  '((delete-fts . "DELETE FROM fts WHERE rowid IN (SELECT id FROM files WHERE path = ?)")
    (delete-file . "DELETE FROM files WHERE path = ?")
    ;; not RETURNING: that needs SQLite 3.35, newer than some macOS releases' system library
    (insert-file . "INSERT INTO files (path, name, stem, title, mtime, size) VALUES (?, ?, ?, ?, ?, ?)")
    (last-id . "SELECT last_insert_rowid()")
    (insert-heading . "INSERT INTO headings VALUES (?, ?, ?, ?, ?)")
    (insert-tag . "INSERT INTO tags VALUES (?, ?, ?, ?)")
    (insert-link . "INSERT INTO links VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    (insert-task . "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    (insert-date . "INSERT INTO dates VALUES (?, ?, ?, ?, ?, ?)")
    (insert-fts . "INSERT INTO fts (rowid, title, body) VALUES (?, ?, ?)")
    (stamp . "SELECT mtime, size FROM files WHERE path = ?")))

(define (stmt idx name)
  (hash-ref! (library-index-stmts idx) name
             (lambda () (prepare (library-index-writer idx) (cdr (assq name statements))))))

(define (w-exec idx name . args) (apply query-exec (library-index-writer idx) (stmt idx name) args))
(define (nullable v) (if v v sql-null))
(define (sym v) (and v (symbol->string v)))

(define (library-index-indexed-path? p)
  (and (member (path-get-extension p) '(#".md" #".markdown" #".txt" #".rkt" #".py")) #t))

(define (remove-row! idx key)
  (when (library-index-fts? idx) (w-exec idx 'delete-fts key))
  (w-exec idx 'delete-file key))

;; Writes one file's rows (replacing any it had). stamp: (cons modify-time-ns size) or #f to stat.
;; A file that cannot be read, or is gone, loses its rows. Must run inside a transaction.
(define (write-file-rows! idx key keywords [stamp #f])
  (define st (or stamp (file-stamp key)))
  (remove-row! idx key)
  (when st
    (define name (path->string (file-name-from-path key)))
    (define stem (path->string (path-replace-extension (string->path name) #"")))
    (define text
      (and (<= (cdr st) (library-index-max-bytes))
           (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
             (define-values (t enc eol note) (decode-file (file->bytes key)))
             (and (not (eq? enc 'binary)) t))))
    (define facts
      (cond [(and text (markdown-path? key))
             (extract-note-facts text (string->path key) name #:heading-keywords keywords)]
            [else (plain-note-facts name)]))
    (w-exec idx 'insert-file key name stem (note-facts-title facts) (car st) (cdr st))
    (define id (query-value (library-index-writer idx) (stmt idx 'last-id)))
    (for ([h (in-list (note-facts-headings facts))])
      (w-exec idx 'insert-heading id (heading-fact-level h) (heading-fact-text h) (heading-fact-pos h) (heading-fact-line h)))
    (for ([t (in-list (note-facts-tags facts))])
      (w-exec idx 'insert-tag id (tag-fact-name t) (nullable (tag-fact-pos t)) (nullable (tag-fact-line t))))
    (for ([l (in-list (note-facts-links facts))])
      (w-exec idx 'insert-link id (sym (link-fact-kind l)) (link-fact-target l) (nullable (link-fact-heading l))
              (nullable (link-fact-resolved l)) (link-fact-pos l) (link-fact-line l) (link-fact-context l)))
    (for ([t (in-list (note-facts-tasks facts))])
      (w-exec idx 'insert-task id (sym (task-fact-kind t)) (sym (task-fact-state t)) (nullable (task-fact-keyword t))
              (task-fact-text t) (nullable (task-fact-due t)) (task-fact-pos t) (task-fact-line t)))
    (for ([d (in-list (note-facts-dates facts))])
      (w-exec idx 'insert-date id (date-fact-date d) (nullable (date-fact-keyword d)) (date-fact-pos d)
              (date-fact-line d) (date-fact-context d)))
    (when (library-index-fts? idx)
      (w-exec idx 'insert-fts id (note-facts-title facts) (or text "")))))

(define (file-stamp p)
  (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
    (and (file-exists? p)
         (let ([st (file-or-directory-stat p)])
           (cons (hash-ref st 'modify-time-nanoseconds) (hash-ref st 'size))))))

(define (stored-stamp idx key)
  (define v (query-maybe-row (library-index-writer idx) (stmt idx 'stamp) key))
  (and v (cons (vector-ref v 0) (vector-ref v 1))))

(define (key-of p) (if (path? p) (path->string p) p))

;; One file, now: re-index it if it is new or changed (or `force?`), drop it if it is gone or not
;; an indexed kind. Returns #t if its rows changed.
(define (library-index-update-file! idx p #:heading-keywords [keywords (heading-state-keyword-list)]
                                    #:force? [force? #f])
  (define key (key-of p))
  (define st (and (library-index-indexed-path? key) (file-stamp key)))
  (cond
    [(not st) (library-index-remove-file! idx key)]
    [(and (not force?) (equal? st (stored-stamp idx key))) #f]
    [else (call-with-transaction (library-index-writer idx) (lambda () (write-file-rows! idx key keywords st))) #t]))

;; Returns #t if the file had rows.
(define (library-index-remove-file! idx p)
  (define key (key-of p))
  (cond
    [(stored-stamp idx key) (call-with-transaction (library-index-writer idx) (lambda () (remove-row! idx key))) #t]
    [else #f]))

;; Brings the index in line with `folders` on disk (see header). Returns the paths written and the
;; paths removed. `stop?` is polled before each file, so a stopping worker never waits for a
;; whole build: the batch in progress rolls back, earlier batches stay committed.
(define (library-index-reconcile! idx folders #:heading-keywords [keywords (heading-state-keyword-list)]
                                  #:force? [force? #f] #:stop? [stop? (lambda () #f)])
  (define disk (make-hash))
  (for ([f (in-list folders)] #:when (directory-exists? f))
    (for ([(k v) (in-hash (scan-library-folder f))]
          #:when (and (pair? v) (library-index-indexed-path? k)))
      (hash-set! disk k v)))
  (define stored
    (for/hash ([(p m s) (in-query (library-index-writer idx) "SELECT path, mtime, size FROM files")])
      (values p (cons m s))))
  (define removed (sort (for/list ([k (in-hash-keys stored)] #:unless (hash-ref disk k #f)) k) string<?))
  (define changed (sort (for/list ([(k v) (in-hash disk)] #:when (or force? (not (equal? v (hash-ref stored k #f))))) k)
                        string<?))
  (define w (library-index-writer idx))
  (let/ec stop
    (for ([batch (in-list (chunk removed batch-size))])
      (call-with-transaction w (lambda () (for ([k (in-list batch)]) (when (stop?) (stop (void))) (remove-row! idx k)))))
    (for ([batch (in-list (chunk changed batch-size))])
      (call-with-transaction w (lambda () (for ([k (in-list batch)])
                                            (when (stop?) (stop (void)))
                                            (write-file-rows! idx k keywords (hash-ref disk k))))))
    (set-library-index-built?! idx #t))
  (values changed removed))

;; Every file re-read, whatever its stamp.
(define (library-index-rebuild! idx folders #:heading-keywords [keywords (heading-state-keyword-list)]
                                #:stop? [stop? (lambda () #f)])
  (library-index-reconcile! idx folders #:heading-keywords keywords #:force? #t #:stop? stop?))

(define (chunk xs n)
  (if (null? xs) '()
      (let-values ([(a b) (if (> (length xs) n) (split-at xs n) (values xs '()))]) (cons a (chunk b n)))))

;; ---- reading -----------------------------------------------------------------------------------

(define the-index #f)
(define (current-library-index) the-index)

(define (library-index-ready? #:index [idx (current-library-index)]) (and idx (library-index-built? idx) #t))

;; Runs a read against the reader connection; any failure (no index, a rebuild swapping the
;; connection) answers `default`.
(define (reading idx default proc)
  (define r (and idx (library-index-reader idx)))
  (if r (with-handlers ([exn:fail? (lambda (e) default)]) (proc r)) default))

(define (false v) (if (sql-null? v) #f v))
(define (->sym v) (and (string? v) (string->symbol v)))

(define (row->note v) (index-note (vector-ref v 0) (vector-ref v 1) (vector-ref v 2)))
(define note-cols "f.path, f.title, f.name")

(define (library-index-note p #:index [idx (current-library-index)])
  (reading idx #f (lambda (r)
                    (define v (query-maybe-row r (string-append "SELECT " note-cols " FROM files f WHERE f.path = ?") (key-of p)))
                    (and v (row->note v)))))

(define (library-index-notes #:index [idx (current-library-index)])
  (reading idx '() (lambda (r) (map row->note (query-rows r (string-append "SELECT " note-cols " FROM files f ORDER BY f.title, f.path"))))))

(define (library-index-headings p #:index [idx (current-library-index)])
  (reading idx '()
           (lambda (r)
             (for/list ([v (in-list (query-rows r "SELECT f.path, h.level, h.text, h.pos, h.line FROM headings h JOIN files f ON f.id = h.file_id WHERE f.path = ? ORDER BY h.pos" (key-of p)))])
               (index-heading (vector-ref v 0) (vector-ref v 1) (vector-ref v 2) (vector-ref v 3) (vector-ref v 4))))))

(define (library-index-note-tags p #:index [idx (current-library-index)])
  (reading idx '()
           (lambda (r)
             (query-list r "SELECT t.tag FROM tags t JOIN files f ON f.id = t.file_id WHERE f.path = ?
                            GROUP BY t.tag ORDER BY min(coalesce(t.pos, -1))" (key-of p)))))

(define (library-index-all-tags #:index [idx (current-library-index)])
  (reading idx '()
           (lambda (r)
             (for/list ([v (in-list (query-rows r "SELECT tag, count(DISTINCT file_id) FROM tags GROUP BY tag ORDER BY tag"))])
               (cons (vector-ref v 0) (vector-ref v 1))))))

(define (library-index-notes-with-tag tag #:index [idx (current-library-index)])
  (define t (regexp-replace #rx"^#" (string-trim tag) ""))
  (reading idx '()
           (lambda (r)
             (map row->note (query-rows r (string-append "SELECT DISTINCT " note-cols " FROM files f JOIN tags t ON t.file_id = f.id
                                                          WHERE t.tag = ? ORDER BY f.title, f.path") t)))))

(define link-cols "f.path, l.kind, l.target, l.heading, l.resolved, l.pos, l.line, l.context")
(define (row->link v)
  (index-link (vector-ref v 0) (->sym (vector-ref v 1)) (false (vector-ref v 2)) (false (vector-ref v 3))
              (false (vector-ref v 4)) (vector-ref v 5) (vector-ref v 6) (vector-ref v 7)))

(define (library-index-links p #:index [idx (current-library-index)])
  (reading idx '()
           (lambda (r)
             (map row->link (query-rows r (string-append "SELECT " link-cols " FROM links l JOIN files f ON f.id = l.file_id
                                                          WHERE f.path = ? ORDER BY l.pos") (key-of p))))))

;; The names a [[wiki link]] may use for the note at `key`: its title (if indexed), its file
;; name, and its file name without extension.
(define (wiki-names r key)
  (define name (path->string (file-name-from-path key)))
  (define stem (path->string (path-replace-extension (string->path name) #"")))
  (define title (query-maybe-value r "SELECT title FROM files WHERE path = ?" key))
  (remove-duplicates (filter values (list title name stem)) string-ci=?))

(define (library-index-links-to p #:index [idx (current-library-index)])
  (define key (key-of p))
  (reading idx '()
           (lambda (r)
             (define names (wiki-names r key))
             (define qs (string-join (for/list ([n names]) "?") ", "))
             (map row->link
                  (apply query-rows r
                         (string-append "SELECT " link-cols " FROM links l JOIN files f ON f.id = l.file_id
                                         WHERE f.path <> ? AND ((l.kind = 'file' AND l.resolved = ?)
                                                                OR (l.kind = 'wiki' AND l.target IN (" qs ")))
                                         ORDER BY f.title, f.path, l.pos")
                         key key names)))))

(define (library-index-resolve-wiki target #:index [idx (current-library-index)])
  (define t (string-trim target))
  (reading idx '()
           (lambda (r)
             (map row->note (query-rows r (string-append "SELECT " note-cols " FROM files f
                                                          WHERE f.title = ? OR f.stem = ? OR f.name = ? COLLATE NOCASE
                                                          ORDER BY f.path") t t t)))))

(define (library-index-tasks #:path [p #f] #:state [state #f] #:due-from [from #f] #:due-to [to #f]
                             #:due? [due? 'any] #:index [idx (current-library-index)])
  (define states (cond [(not state) #f] [(symbol? state) (list state)] [else state]))
  (define-values (where args)
    (conds (and p (list "f.path = ?" (key-of p)))
           (and states (cons (string-append "t.state IN (" (string-join (map (lambda (s) "?") states) ", ") ")")
                             (map symbol->string states)))
           (and from (list "t.due >= ?" from))
           (and to (list "t.due <= ?" to))
           (and (eq? due? #t) (list "t.due IS NOT NULL"))
           (and (eq? due? #f) (list "t.due IS NULL"))))
  (reading idx '()
           (lambda (r)
             (for/list ([v (in-list (apply query-rows r (string-append "SELECT f.path, t.kind, t.state, t.keyword, t.text, t.due, t.pos, t.line
                                                                         FROM tasks t JOIN files f ON f.id = t.file_id" where
                                                                        " ORDER BY t.due IS NULL, t.due, f.path, t.pos")
                                           args))])
               (index-task (vector-ref v 0) (->sym (vector-ref v 1)) (->sym (vector-ref v 2)) (false (vector-ref v 3))
                           (vector-ref v 4) (false (vector-ref v 5)) (vector-ref v 6) (vector-ref v 7))))))

(define (library-index-dates #:path [p #f] #:from [from #f] #:to [to #f] #:keyword [kw #f]
                             #:index [idx (current-library-index)])
  (define-values (where args)
    (conds (and p (list "f.path = ?" (key-of p)))
           (and from (list "d.date >= ?" from))
           (and to (list "d.date <= ?" to))
           (and kw (list "d.keyword = ? COLLATE NOCASE" kw))))
  (reading idx '()
           (lambda (r)
             (for/list ([v (in-list (apply query-rows r (string-append "SELECT f.path, d.date, d.keyword, d.pos, d.line, d.context
                                                                         FROM dates d JOIN files f ON f.id = d.file_id" where
                                                                        " ORDER BY d.date, f.path, d.pos")
                                           args))])
               (index-date (vector-ref v 0) (vector-ref v 1) (false (vector-ref v 2)) (vector-ref v 3) (vector-ref v 4) (vector-ref v 5))))))

;; A WHERE clause from optional (sql arg ...) conditions.
(define (conds . cs)
  (define live (filter values cs))
  (values (if (null? live) "" (string-append " WHERE " (string-join (map car live) " AND ")))
          (append-map cdr live)))

;; Plain words to an FTS5 query: each word a quoted string (so no word is ever FTS syntax), the
;; last one a prefix. #f when there are no words.
(define (fts-query text)
  (define words (string-split text))
  (and (pair? words)
       (string-join (for/list ([w (in-list words)] [i (in-naturals 1)])
                      (string-append "\"" (string-replace w "\"" "\"\"") "\"" (if (= i (length words)) "*" "")))
                    " ")))

(define (library-index-search text #:limit [limit 50] #:open [open "["] #:close [close "]"]
                              #:index [idx (current-library-index)])
  (define q (fts-query text))
  (cond
    [(not q) '()]
    [(and idx (library-index-fts? idx))
     (reading idx '()
              (lambda (r)
                (for/list ([v (in-list (query-rows r "SELECT f.path, f.title, snippet(fts, 1, ?, ?, '…', 12)
                                                      FROM fts JOIN files f ON f.id = fts.rowid
                                                      WHERE fts MATCH ? ORDER BY bm25(fts) LIMIT ?"
                                                   open close q limit))])
                  (index-hit (vector-ref v 0) (vector-ref v 1) (string-normalize-spaces (vector-ref v 2))))))]
    [else ; no FTS5 in this libsqlite3: titles only
     (reading idx '()
              (lambda (r)
                (for/list ([v (in-list (query-rows r "SELECT path, title FROM files WHERE title LIKE ? ORDER BY title LIMIT ?"
                                                   (string-append "%" (string-trim text) "%") limit))])
                  (index-hit (vector-ref v 0) (vector-ref v 1) ""))))]))

;; ---- the app's index: a worker thread ----------------------------------------------------------

(define worker #f)            ; the thread
(define worker-stopping (box #f))
(define gui-eventspace #f)

;; Runs on the GUI thread (hooks and error reports), as watch.rkt delivers its events.
(define (on-gui thunk)
  (when gui-eventspace
    (parameterize ([current-eventspace gui-eventspace]) (queue-callback thunk))))

(define (report! e) (on-gui (lambda () (report-error! 'library-index e))))
(define (announce! paths) (when (pair? paths) (on-gui (lambda () (run-hook 'library-index-changed paths)))))

(define (send-job! msg) (when worker (thread-send worker msg #f)))

;; Messages carry the settings they need, read here on the GUI thread.
(define (reconcile-job [force? #f]) (list 'reconcile (library-folder-paths) (heading-state-keyword-list) force?))

(define (run-job idx msg)
  (define stop? (lambda () (unbox worker-stopping)))
  (case (car msg)
    [(reconcile)
     (define-values (changed removed)
       (library-index-reconcile! idx (cadr msg) #:heading-keywords (caddr msg) #:force? (cadddr msg) #:stop? stop?))
     (announce! (append changed removed))]
    [(update)
     (when (library-index-update-file! idx (cadr msg) #:heading-keywords (caddr msg)) (announce! (list (cadr msg))))]
    [(remove)
     (when (library-index-remove-file! idx (cadr msg)) (announce! (list (cadr msg))))]
    [(sync) (semaphore-post (cadr msg))]))

;; A SQL error means a damaged database: start over from the notes. If the very next job fails
;; too, starting over did not help (the same statement fails every time), so the index gives up
;; for this session -- closed, queries answer empty -- rather than rebuilding in a loop.
(define (worker-loop idx)
  (let loop ([just-reset? #f])
    (define msg (thread-receive))
    (cond
      [(eq? msg 'stop) (void)]
      [(and (not (library-index-writer idx)) (not (eq? (car msg) 'sync))) (loop just-reset?)]   ; gave up
      [else
       (define outcome
         (with-handlers ([exn:fail:sql?
                          (lambda (e)
                            (report! e)
                            (cond
                              [just-reset? (close-library-index idx) 'gave-up]
                              [else
                               (with-handlers ([exn:fail? report!])
                                 (reset-library-index! idx report!)
                                 (thread-send (current-thread)
                                              (list 'reconcile (library-folder-paths*) (heading-state-keyword-list*) #f) #f))
                               'reset]))]
                         [exn:fail? (lambda (e) (report! e) 'ok)])
           (run-job idx msg)
           'ok))
       (loop (cond [(eq? outcome 'reset) #t]
                   [(eq? (car msg) 'sync) just-reset?]   ; a wait in between proves nothing
                   [else #f]))])))

;; The worker's copy of the last settings it was sent (a reset needs them off the GUI thread).
(define last-folders '())
(define last-keywords '("TODO" "WAITING" "DONE"))
(define (library-folder-paths*) last-folders)
(define (heading-state-keyword-list*) last-keywords)
(define (remember-settings! msg)
  (when (eq? (car msg) 'reconcile) (set! last-folders (cadr msg)) (set! last-keywords (caddr msg))))

;; Blocks until the worker has handled everything sent before this call. For tests: never from
;; the GUI thread while a build may be running (it would hold the window for that long). #f on
;; timeout or with no worker.
(define (library-index-wait! [timeout 30])
  (cond
    [worker (define s (make-semaphore 0))
            (send-job! (list 'sync s))
            (and (sync/timeout timeout s) #t)]
    [else #f]))

;; ---- wiring ------------------------------------------------------------------------------------

(define (under-library-key p)
  (define key (path->string (simplify-path (path->complete-path p))))
  (and (library-index-indexed-path? key)
       (for/or ([f (in-list (library-folder-paths))])
         (define prefix (if (regexp-match? #rx"/$" f) f (string-append f "/")))
         (and (string-prefix? key prefix)
              (let ([parts (string-split (substring key (string-length prefix)) "/")])
                (and (pair? parts)
                     (not (for/or ([x (in-list parts)]) (regexp-match? #rx"^[.]" x)))
                     (not (for/or ([x (in-list (drop-right parts 1))]) (member x skip-library-dirs)))))
              key))))

(define (on-file-changed kind path folder)
  (define key (key-of path))
  (case kind
    [(removed) (send-job! (list 'remove key))]
    [else (when (library-index-indexed-path? key) (send-job! (list 'update key (heading-state-keyword-list))))]))

(define (on-after-save b)
  (define p (send b get-path))
  (define key (and p (under-library-key p)))
  (when key (send-job! (list 'update key (heading-state-keyword-list)))))

(define (on-setting-changed name . _)
  (case name
    [(library-folders) (send-job! (remember (reconcile-job)))]
    [(heading-state-keywords) (send-job! (remember (reconcile-job #t)))]))

(define (remember msg) (remember-settings! msg) msg)

(define exit-flush #f)

;; file: where the database lives (tests pass their own, or 'memory).
(define (enable-library-index! #:file [file (library-index-file-path)])
  (unless worker
    (set! gui-eventspace (current-eventspace))
    (set-box! worker-stopping #f)
;; Opened by the worker, so a quick_check (or a rebuild) never holds up the window; until
    ;; then queries answer empty.
    (define idx (make-library-index file #f #f #f #f #f #f))
    (set! the-index idx)
    (add-hook! 'library-file-changed on-file-changed)
    (add-hook! 'after-save on-after-save)
    (add-hook! 'setting-changed on-setting-changed)
    (unless exit-flush
      (set! exit-flush (plumber-add-flush! (current-plumber) (lambda (h) (disable-library-index!)))))
    (set! worker (thread (lambda ()
                           (with-handlers ([exn:fail? report!]) (connect! idx report!))
                           (worker-loop idx))))
    (send-job! (remember (reconcile-job)))))

(define (disable-library-index!)
  (remove-hook! 'library-file-changed on-file-changed)
  (remove-hook! 'after-save on-after-save)
  (remove-hook! 'setting-changed on-setting-changed)
  (when exit-flush (plumber-flush-handle-remove! exit-flush) (set! exit-flush #f))
  (when worker
    (set-box! worker-stopping #t)           ; a pass in progress stops at its next file
    (thread-send worker 'stop #f)
    ;; The worker is never killed: a thread killed inside a query can leave the connection
    ;; locked (db docs, "kill-safe"). It stops between files, so this wait is short.
    (sync/timeout 10 worker)
    (set! worker #f))
  (when the-index (close-library-index the-index) (set! the-index #f)))
