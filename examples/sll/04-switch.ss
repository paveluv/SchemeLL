;;; Control flow: switch with a default, plus unconditional branches.
(import (chezscheme) (prefix (sll) sll:))

(define day-type
  (sll:procedure
    '((define i64 (@day_type (i64 %day))      ; 0=weekend 1=weekday 2=unknown
        (label %entry
          (switch i64 %day (label %unknown)
            ((i64 0) (label %weekend))
            ((i64 6) (label %weekend))
            ((i64 1) (label %weekday)) ((i64 2) (label %weekday))
            ((i64 3) (label %weekday)) ((i64 4) (label %weekday))
            ((i64 5) (label %weekday))))
        (label %weekend (ret i64 0))
        (label %weekday (ret i64 1))
        (label %unknown (ret i64 2))))
    "day_type"))

(do ([d 0 (+ d 1)]) ((> d 7))
  (printf "day ~a -> ~a~%" d (day-type d)))
