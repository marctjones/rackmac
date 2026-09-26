#lang racket/base
;; Layout metrics on a 4 px grid (docs/UI-DESIGN.md section 1.4). One place, so the
;; window, dialogs and later surfaces stay consistent.
(provide (all-defined-out))

(define grid 4)
(define editor-inset-x 16)          ; space between the window edge and the text
(define editor-inset-y 12)
(define row-border 0)               ; window rows sit flush
(define bar-border 8)               ; find row, InfoBar
(define bar-spacing 8)
(define dialog-border 16)
(define dialog-spacing 12)
(define toolbar-spacing 4)
(define toolbar-group-gap 8)
(define status-bar-height (if (eq? (system-type 'os) 'macosx) 22 24))
(define prose-measure 80)           ; characters per line for prose Languages
(define prose-inset-y 48)           ; space above a note's first line (space-12): a page, not a pane

;; The editor's horizontal inset that centers a `measure`-wide column of text in a view
;; `view-width` wide, never less than the normal inset. #f measure: the normal inset.
(define (centered-inset view-width measure)
  (if measure
      (max editor-inset-x (quotient (- view-width (inexact->exact (ceiling measure))) 2))
      editor-inset-x))
