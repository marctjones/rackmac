#lang racket/base
;; File > Open Recent (#275): the submenu lists the recent-files store (#274), rebuilt fresh
;; every time it opens, with an empty-state placeholder and a Clear item -- tested the same way
;; RM-065's other on-demand menus are (context-menu-test.rkt): (send (menu-for-title ...)
;; on-demand), then read its items.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt"
         "../rackmac/library/recents.rkt" "../rackmac/library/open-recent.rkt")

(define dir (make-temporary-file "rackmac-openrecent~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))

(define f (make-main-frame))          ; hidden: show is never called

(define (labels m) (for/list ([i (send m get-items)] #:unless (is-a? i separator-menu-item%)) (send i get-label)))
(define (item-at m i) (list-ref (send m get-items) i))
(define (click! item) (send item command (new control-event% [event-type 'menu])))

(define (touch! name)
  (define p (build-path dir name))
  (display-to-file (symbol->string (gensym)) p #:exists 'truncate)
  (record-recent-open! (path->string p) 0)
  p)

(test-case "the submenu exists under File and is rebuilt on demand"
  (check-not-false (menu-for-title "Open Recent")))

(test-case "an empty store shows a disabled placeholder, no Clear"
  (clear-recent-files!)
  (define m (menu-for-title "Open Recent"))
  (send m on-demand)
  (check-equal? (labels m) '("Files you open appear here."))
  (check-false (send (item-at m 0) is-enabled?)))

(test-case "it lists recent files, most-recent first, with Clear below a separator"
  (clear-recent-files!)
  (touch! "a.md")
  (touch! "b.md")
  (define m (menu-for-title "Open Recent"))
  (send m on-demand)
  (check-equal? (labels m) '("b.md" "a.md" "Clear Recent Files"))
  (check-true (is-a? (item-at m 2) separator-menu-item%)))

(test-case "clicking a recent entry opens it"
  (clear-recent-files!)
  (touch! "click.md")
  (define m (menu-for-title "Open Recent"))
  (send m on-demand)
  (click! (item-at m 0))
  (check-equal? (send (current-buffer) get-name) "click.md"))

(test-case "Clear Recent Files empties the store, and the menu reflects it next time it opens"
  (clear-recent-files!)
  (touch! "c.md")
  (define m (menu-for-title "Open Recent"))
  (send m on-demand)
  (check-equal? (length (labels m)) 2 "the file, then Clear")
  (click! (item-at m (sub1 (length (send m get-items)))))   ; last item = Clear (after the separator)
  (send m on-demand)
  (check-equal? (labels m) '("Files you open appear here.")))

(test-case "two recent files with the same name are disambiguated by their folder"
  (clear-recent-files!)
  (make-directory* (build-path dir "one"))
  (make-directory* (build-path dir "two"))
  (touch! "one/Notes.md")
  (touch! "two/Notes.md")
  (define m (menu-for-title "Open Recent"))
  (send m on-demand)
  (check-equal? (labels m) (list "Notes.md  (two)" "Notes.md  (one)" "Clear Recent Files")))
