#lang racket/base
;; Files docs/roadmap.rktd on GitHub: labels, one GitHub milestone per roadmap milestone,
;; one issue per roadmap issue (already-delivered ones are closed), one tracking issue per epic.
;;
;;   racket tools/github-sync.rkt --repo OWNER/NAME [--dry-run]
;;
;; Resumable: progress is saved in .github-sync-state.rktd, so a rerun skips what exists.
;; Issues are created in roadmap order into an EMPTY repository, so issue number N is roadmap
;; item RM-N; that is what lets bodies link dependencies as #N. The tool stops if numbers diverge.
(require racket/list racket/string racket/port racket/file racket/match racket/format racket/cmdline
         racket/runtime-path "roadmap.rkt")

(define-runtime-path state-path "../.github-sync-state.rktd")

(define repo #f)
(define dry? #f)
(command-line
 #:once-each
 [("--repo") r "OWNER/NAME" (set! repo r)]
 [("--dry-run") "print what would be done; call nothing" (set! dry? #t)])
(unless repo (eprintf "usage: racket tools/github-sync.rkt --repo OWNER/NAME [--dry-run]\n") (exit 2))

;; ---- running gh ----------------------------------------------------------

(define gh-exe (or (find-executable-path "gh") (error "the GitHub CLI (gh) was not found on PATH")))

(define (run-gh stdin . args)
  (define-values (sp out in err) (apply subprocess #f #f #f gh-exe args))
  (when stdin (write-string stdin in))
  (close-output-port in)
  (define e "")
  (define t (thread (lambda () (set! e (port->string err)))))
  (define o (port->string out))
  (thread-wait t)
  (subprocess-wait sp)
  (values (subprocess-status sp) o e))

;; Retries on GitHub rate limiting; anything else is a hard error.
(define (gh! #:stdin [stdin #f] . args)
  (if dry?
      (begin (printf "  DRY: gh ~a\n" (string-join (map (lambda (a) (if (> (string-length a) 60) (string-append (substring a 0 57) "...") a)) args) " "))
             "")
      (let loop ([tries 0])
        (define-values (status out err) (apply run-gh stdin args))
        (cond
          [(zero? status) out]
          [(and (< tries 5) (regexp-match? #rx"(?i:rate limit|secondary|abuse|retry-after| 429)" err))
           (eprintf "  rate limited; waiting 70s (~a)\n" (string-trim err)) (sleep 70) (loop (add1 tries))]
          [else (error 'gh "failed: gh ~a\n~a" (string-join args " ") err)]))))

(define (pause) (unless dry? (sleep 1.4)))              ; stay well under content-creation limits

;; ---- state ---------------------------------------------------------------

(define state (if (file-exists? state-path) (call-with-input-file state-path read) (hash)))
(define (state-ref k) (hash-ref state k (hash)))
(define (state-set! k key v)
  (set! state (hash-set state k (hash-set (state-ref k) key v)))
  (unless dry? (call-with-output-file state-path #:exists 'truncate (lambda (o) (write state o)))))

;; ---- roadmap -------------------------------------------------------------

(define rm (load-roadmap))
(let ([errs (validate rm)]) (unless (null? errs) (for-each (lambda (e) (eprintf "~a\n" e)) errs) (exit 1)))
(define issues (flatten-issues rm))
(define by-key (for/hasheq ([i issues]) (values (iss-key i) i)))
(define epics (filter (lambda (x) (eq? (car x) 'epic)) (cdr rm)))
(define releases (cdr (assq 'releases (cdr rm))))
(define (rm-id i) (format "RM-~a" (~r (iss-num i) #:min-width 3 #:pad-string "0")))
(define (release-of epic-name)
  (or (for/first ([r releases] #:when (memq epic-name (third r))) (first r))
      "Icebox"))                                          ; not scheduled into any release
(define (epic-named name) (findf (lambda (e) (eq? (cadr e) name)) epics))
(define (epic-title e) (caddr e))
(define (milestone-title id title) (format "~a ~a" id title))
(define milestone-names            ; milestone symbol -> GitHub milestone title
  (for*/hasheq ([e epics] [m (list-tail e 5)]) (values (cadr m) (milestone-title (cadr m) (caddr m)))))
(define sub-titles (for*/hasheq ([e epics] [m (list-tail e 5)] [s (cdddr m)]) (values (cadr s) (caddr s))))
(define milestone-of-title
  (for*/hasheq ([e epics] [m (list-tail e 5)]) (values (cadr m) (caddr m))))

;; ---- labels --------------------------------------------------------------

;; GitHub rejects label descriptions over 100 characters.
(define (clip s [n 100]) (if (> (string-length s) n) (string-append (substring s 0 (- n 3)) "...") s))

(define (ensure-labels!)
  (define wanted
    (append
     (list (list "epic" "3e4b9e" "Tracking issue for an epic")
           (list "icebox" "cccccc" "Parked: not scheduled")
           (list "size:S" "c5def5" "Under half a day")
           (list "size:M" "c5def5" "One to two days")
           (list "size:L" "c5def5" "Three to five days"))
     (for/list ([e epics]) (list (format "epic:~a" (cadr e)) "5319e7" (epic-title e)))
     (for/list ([r releases]) (list (format "release:~a" (car (string-split (first r)))) "0e8a16" (format "~a: ~a" (first r) (second r))))
     (list (list "release:Icebox" "cccccc" "Not scheduled into any release"))))
  (for ([w wanted] #:unless (hash-ref (state-ref 'labels) (car w) #f))
    (printf "label ~a\n" (car w))
    (gh! "label" "create" (car w) "--repo" repo "--color" (cadr w) "--description" (clip (caddr w)) "--force")
    (state-set! 'labels (car w) #t)
    (pause)))

;; ---- milestones ----------------------------------------------------------

(define (ensure-milestones!)
  (for* ([e epics] [m (list-tail e 5)]
         #:unless (hash-ref (state-ref 'milestones) (cadr m) #f))
    (define title (milestone-title (cadr m) (caddr m)))
    (printf "milestone ~a\n" title)
    (gh! "api" (format "repos/~a/milestones" repo) "-X" "POST" "-f" (format "title=~a" title)
         "-f" (format "description=Epic ~a: ~a. Release: ~a." (cadr e) (epic-title e) (release-of (cadr e))))
    (state-set! 'milestones (cadr m) #t)
    (pause)))

;; ---- issues --------------------------------------------------------------

(define (issue-number-ref key) (format "#~a" (iss-num (hash-ref by-key key))))

(define (issue-body i)
  (define e (epic-named (iss-epic i)))
  (define acc (filter (lambda (x) (not (string=? x ""))) (map string-trim (string-split (iss-accept i) "|"))))
  (define done? (eq? (iss-status i) 'done))
  (string-append
   (format "**Epic:** ~a: ~a  \n**Milestone:** ~a  \n**Sub-milestone:** ~a: ~a  \n**Size:** ~a · **Release:** ~a · **Roadmap ID:** ~a\n\n"
           (iss-epic i) (epic-title e)
           (hash-ref milestone-names (iss-milestone i))
           (iss-sub i) (hash-ref sub-titles (iss-sub i))
           (iss-size i) (release-of (iss-epic i)) (rm-id i))
   (if (null? acc)
       ""
       (string-append "### Acceptance criteria\n\n"
                      (string-join (for/list ([a acc]) (format "- [~a] ~a" (if done? "x" " ") a)) "\n") "\n\n"))
   (if (null? (iss-deps i))
       ""
       (string-append "### Depends on\n\n"
                      (string-join (for/list ([d (iss-deps i)])
                                     (define di (hash-ref by-key d))
                                     (format "- ~a ~a" (issue-number-ref d) (iss-title di))) "\n") "\n\n"))
   (format "_Filed from `docs/roadmap.rktd` (~a). From here on, this issue is the source of truth for its status._\n"
           (rm-id i))))

(define (issue-labels i)
  (append (list (format "epic:~a" (iss-epic i))
                (format "size:~a" (iss-size i))
                (format "release:~a" (car (string-split (release-of (iss-epic i))))))
          (if (eq? (iss-status i) 'icebox) (list "icebox") '())))

(define (create-issues!)
  (for ([i issues] #:unless (hash-ref (state-ref 'issues) (iss-key i) #f))
    (printf "issue ~a ~a\n" (rm-id i) (iss-title i))
    (define out
      (apply gh! #:stdin (issue-body i)
             "issue" "create" "--repo" repo
             "--title" (format "[~a] ~a" (rm-id i) (iss-title i))
             "--body-file" "-"
             "--milestone" (hash-ref milestone-names (iss-milestone i))
             (append* (for/list ([l (issue-labels i)]) (list "--label" l)))))
    (define n (if dry? (iss-num i) (string->number (last (string-split (string-trim out) "/")))))
    (unless (equal? n (iss-num i))
      (error 'github-sync "issue numbers diverged: ~a became #~a (the repository must start empty). Stopping." (rm-id i) n))
    (state-set! 'issues (iss-key i) n)
    (pause)
    (when (eq? (iss-status i) 'done)
      (gh! "issue" "close" (number->string n) "--repo" repo "--reason" "completed"
           "--comment" "Delivered before this issue tracker existed; covered by the automated tests.")
      (pause))))

;; ---- epic tracking issues --------------------------------------------------

(define (epic-body e)
  (match-define (list* 'epic name title goal ref milestones) e)
  (string-append
   (format "~a\n\n**Design:** ~a  \n**Release:** ~a\n\n" goal ref (release-of name))
   (string-append*
    (for/list ([m milestones])
      (string-append
       (format "## ~a\n\n" (hash-ref milestone-names (cadr m)))
       (string-append*
        (for/list ([s (cdddr m)])
          (string-append
           (format "**~a: ~a**\n\n" (cadr s) (caddr s))
           (string-join
            (for/list ([i issues] #:when (eq? (iss-sub i) (cadr s)))
              (format "- [~a] #~a ~a" (if (eq? (iss-status i) 'done) "x" " ") (iss-num i) (iss-title i)))
            "\n")
           "\n\n"))))))))

(define (create-epics!)
  (for ([e epics] #:unless (hash-ref (state-ref 'epics) (cadr e) #f))
    (printf "epic ~a ~a\n" (cadr e) (epic-title e))
    (define out
      (gh! #:stdin (epic-body e)
           "issue" "create" "--repo" repo
           "--title" (format "Epic ~a: ~a" (cadr e) (epic-title e))
           "--body-file" "-" "--label" "epic" "--label" (format "epic:~a" (cadr e))))
    (state-set! 'epics (cadr e) (if dry? 0 (string->number (last (string-split (string-trim out) "/")))))
    (pause)))

(printf "~a: ~a roadmap issues, ~a epics~a\n" repo (length issues) (length epics) (if dry? " (dry run)" ""))
(ensure-labels!)
(ensure-milestones!)
(create-issues!)
(create-epics!)
(printf "done.\n")
