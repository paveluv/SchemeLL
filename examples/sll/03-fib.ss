;;; Two mutually calling functions in one program.
(import (chezscheme) (prefix (sll) sll:))

[define
 prog
 '[[define
    i64
    (@fib (i64 %n))
    [label
     %entry
     (= %small (icmp slt i64 %n 2))
     (br i1 %small (label %base) (label %rec))]
    (label %base (ret i64 %n))
    [label
     %rec
     (= %n1 (sub i64 %n 1))
     (= %n2 (sub i64 %n 2))
     (= %f1 (call i64 (@fib (i64 %n1))))
     (= %f2 (call i64 (@fib (i64 %n2))))
     (= %r (add i64 %f1 %f2))
     (ret i64 %r)]]]]

(define fib (sll:procedure prog "fib"))
(do ((i 0 (+ i 1))) ((> i 12)) (printf "fib(~a) = ~a~%" i (fib i)))
