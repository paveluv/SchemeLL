;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; The sll pitch in one example: programs are plain data, so quasiquote IS the
;;; macro system. Generate a fully unrolled x^n at run time.
(import (chezscheme) (prefix (sll) sll:))

[define
 (power-prog n)
 `[[define
    i64
    (@pow (i64 %x))
    [label
     %entry
     ,@[let
        loop
        ((i 1) (prev '%x) (acc '()))
        [if
         (>= i n)
         (reverse (cons `(ret i64 ,prev) acc))
         [let
          ((next (sll:name '%p i)))
          (loop (+ i 1) next (cons `(= ,next (mul i64 ,prev %x)) acc))]]]]]]]

(printf "generated program for x^5:~%~s~%~%" (power-prog 5))
(define pow5 (sll:procedure (power-prog 5) "pow"))
(printf "3^5 = ~a~%" (pow5 3))
(define pow11 (sll:procedure (power-prog 11) "pow"))
(printf "2^11 = ~a~%" (pow11 2))
