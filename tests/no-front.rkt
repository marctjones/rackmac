#lang racket/base
;; Required first by every GUI test: windows and dialogs made by tests must never take
;; keyboard focus away from whatever the person at the machine is doing.
(require "../rackmac/no-front.rkt")
(enable-no-front!)
