#lang racket/base
;; Turns GUI key events into normalized keys and dispatches them through the
;; buffer's keymap layers. Uses only `send` on the event object (no GUI import),
;; so it can be exercised with synthetic key events in tests.
(require racket/class racket/list
         "keymap.rkt" "command.rkt" "hook.rkt" "platform.rkt")
(provide event->key dispatch-key-event request-describe-key! pending-keys)

;; On macOS (verified in Racket's Cocoa backend): control-down = Control,
;; meta-down = Command, alt-down = Option. Windows Ctrl maps to control-down.
(define (char-base c)
  (case c
    [(#\return) 'enter] [(#\tab) 'tab] [(#\backspace) 'backspace] [(#\rubout) 'delete]
    [(#\space) (quote space)] [(#\u1B) (quote escape)]
    [else (char-downcase c)]))

(define (symbol-base s)
  (case s
    [(left right up down home end escape insert delete) s]
    [(prior) 'pageup] [(next) 'pagedown] [(numpad-enter) 'enter]
    [(f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20) s]
    [else #f]))       ; 'release, bare modifiers, wheel events, ...: not ours

;; How racket/gui reports modifiers (see the key-event% docs):
;;   macOS:   meta-down = Command, alt-down = Option, control-down = Control.
;;   Windows: meta-down = Alt (alt-down is never set), control-down = Ctrl; AltGr arrives
;;            as Ctrl+Alt with get-control+meta-is-altgr true, and must type, not dispatch.
(define (event->key ev)
  (define code (send ev get-key-code))
  (define shift? (send ev get-shift-down))
  (define ctrl? (send ev get-control-down))
  (define alt? (if (mac?) (send ev get-alt-down) (or (send ev get-meta-down) (send ev get-alt-down))))
  (define cmd? (and (mac?) (send ev get-meta-down)))
  (define altgr? (and (not (mac?)) ctrl? alt? (send ev get-control+meta-is-altgr)))
  (define altgr-code (send ev get-other-altgr-key-code))
  (define shift-code (send ev get-other-shift-key-code))
  (define base
    (cond
      [(char? code)
       (char-base
        (cond [(and alt? (mac?) (char? altgr-code)) altgr-code]    ; Option+a arrives as å
              [(and shift? (char? shift-code)) shift-code]         ; Shift+p arrives as P
              [else code]))]
      [(symbol? code) (symbol-base code)]
      [else #f]))
  (and base
       (not (and altgr? (char? code)))            ; AltGr+q = @ : let text% insert it
       (key base (for/list ([m '(ctrl alt shift cmd)]
                            [down? (list ctrl? alt? shift? cmd?)]
                            #:when down?)
                   m))))

;; Keys typed so far in an unfinished chord, most recent first.
(define pending '())
(define (pending-keys) (reverse pending))
(define (set-pending! ks)
  (set! pending ks)
  (run-hook 'echo (if (null? ks) "" (string-append (key-sequence->string (reverse ks)) " …"))))

(define describe-pending? #f)
(define (request-describe-key!)
  (set! describe-pending? #t)
  (run-hook 'echo "Describe key: press a key…"))

(define (without-shift k)
  (key (key-base k) (remq 'shift (key-mods k))))

;; Unbound modified keys must not fall through to text%'s built-in Emacs-style keymap on
;; Windows, and Cmd combos must not insert stray characters on macOS. Mac Control combos
;; are left alone on purpose: Ctrl+A/E/K/F/B/N/P are native macOS text navigation.
(define (swallow-unbound? k)
  (define mods (key-mods k))
  (cond [(mac?) (and (memq 'cmd mods) #t)]
        [else (and (or (memq 'ctrl mods) (memq 'alt mods))
                   (not (and (memq 'ctrl mods) (memq 'alt mods) (char? (key-base k))))  ; AltGr
                   #t)]))

;; Returns #t when the event was consumed.
(define keylog? (and (getenv "RACKMAC_KEYLOG") #t))   ; RACKMAC_KEYLOG=1: log key events to stderr

(define (dispatch-key-event buf ev)
  (define k (event->key ev))
  (when keylog?
    (eprintf "KEY code=~s ctrl=~a alt=~a meta=~a shift=~a -> ~a\n" (send ev get-key-code)
             (send ev get-control-down) (send ev get-alt-down) (send ev get-meta-down)
             (send ev get-shift-down) (and k (key->string k)))
    (flush-output (current-error-port)))
  (cond
    [(not k) #f]
    [describe-pending?
     (set! describe-pending? #f)
     (define-values (kind name) (lookup-key (send buf get-keymaps) (list k)))
     (run-hook 'echo
               (case kind
                 [(command) (format "~a runs ~a" (key->string k) name)]
                 [(prefix) (format "~a is a prefix key" (key->string k))]
                 [else (format "~a is not bound" (key->string k))]))
     #t]
    [(and (pair? pending) (eq? (key-base k) 'escape))
     (set-pending! '())
     #t]
    [else
     (define ks (reverse (cons k pending)))
     (define-values (kind name) (lookup-key (send buf get-keymaps) ks))
     (case kind
       [(command)
        (set-pending! '())
        (run-command/safe name)
        #t]
       [(prefix) (set-pending! (cons k pending)) #t]
       [else
        (cond
          [(pair? pending)
           (define shown (key-sequence->string ks))
           (set-pending! '())
           (run-hook 'echo (string-append shown " is undefined"))
           #t]
          [(and (memq 'shift (key-mods k))
                (let-values ([(kind2 name2) (lookup-key (send buf get-keymaps) (list (without-shift k)))])
                  (and (eq? kind2 'command)
                       (let ([c (find-command name2)]) (and c (memq name2 selection-extenders) name2)))))
           => (lambda (name2)
                (parameterize ([extending-selection? #t]) (run-command/safe name2))
                #t)]
          [else (swallow-unbound? k)])])]))

;; Motion commands that can extend the selection when Shift is added.
(define selection-extenders
  '(word-left word-right line-start line-end doc-start doc-end page-up page-down))
