;;; (tests harness) -- minimal test harness: named checks, counted results.
;;; Import as: (prefix (tests harness) t:)
[library
 (tests harness)
 (export check check-exn section summary-and-exit)
 (import (chezscheme))

 (define passed 0)
 (define failed 0)

 (define (section name) (printf "~%== ~a ==~%" name))

 (define (pass! label) (set! passed (+ passed 1)) (printf "  ok    ~a~%" label))

 [define
  (fail! label why)
  (set! failed (+ failed 1))
  (printf "  FAIL  ~a: ~a~%" label why)]

 [define
  (condition->string e)
  (with-output-to-string (lambda () (display-condition e)))]

 [define
  (run-check label thunk)
  [guard
   (e (#t (fail! label (condition->string e))))
   (if (thunk) (pass! label) (fail! label "check returned #f"))]]

 ;; (t:check "label" expr) -- passes iff expr is true; exceptions fail.
 [define-syntax
  check
  (syntax-rules () ((_ label expr) (run-check label (lambda () expr))))]

 ;; (t:check-exn "label" expr) -- passes iff expr raises.
 [define-syntax
  check-exn
  [syntax-rules
   ()
   ((_ label expr) (run-check label (lambda () (guard (e (#t #t)) expr #f))))]]

 [define
  (summary-and-exit)
  (printf "~%~a passed, ~a failed~%" passed failed)
  (exit (if (zero? failed) 0 1))]]
