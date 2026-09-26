#lang racket/base
;; File > Open Recent ("open-recent" #275): a submenu of the recent-files store (#274), rebuilt
;; from it every time the submenu opens (frame.rkt's register-submenu!, since it is data-driven
;; rather than a fixed command like the rest of the File menu), plus Clear Recent Files.
(require racket/class racket/gui/base racket/list racket/path
         "recents.rkt" "../frame.rkt" "../editor.rkt")
(provide entry-label)   ; the sidebar's Recent section labels its rows the same way (#273)

;; The sidebar's own Recent list shows the last 10 (docs/UI-DESIGN.md); Open Recent matches it.
;; The store itself keeps up to 50 for that list, the start screen and search to draw on.
(define shown-count 10)

;; Files that share a base name are disambiguated by their parent folder, the way Finder and
;; Word do, instead of several indistinguishable "Notes.md" entries.
(define (entry-label e all)
  (define name (recent-entry-name e))
  (cond
    [(> (count (lambda (o) (equal? (recent-entry-name o) name)) all) 1)
     (define-values (parent file dir?) (split-path (recent-entry-path e)))
     ;; `parent` is a directory path (a trailing separator), so file-name-from-path would see
     ;; no name component; split it again to get the folder's own bare name ("one", not "one/").
     (define-values (grandparent folder-name gdir?) (split-path parent))
     (format "~a  (~a)" name (path->string folder-name))]
    [else name]))

(define (populate! m)
  (define es (recent-entries shown-count))
  (cond
    [(null? es)
     (define none (new menu-item% [label "Files you open appear here."] [parent m] [callback void]))
     (send none enable #f)]
    [else
     (for ([e (in-list es)])
       (define path (recent-entry-path e))
       (new menu-item% [label (entry-label e es)] [parent m]
            [callback (lambda (i ev) (set-current-buffer! (open-file! path)))]))
     (new separator-menu-item% [parent m])
     (new menu-item% [label "Clear Recent Files"] [parent m]
          [callback (lambda (i ev) (clear-recent-files!))])]))

(register-submenu! "Open Recent" #:menu "File" #:menu-order 13 populate!)
