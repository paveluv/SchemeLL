;;; @fact, live: an sll program (plain data!) compiled in memory and called.
;;; Run with: scheme --libdirs . --script examples/sll/02-fact.ss
(import (chezscheme) (prefix (sll) sll:))

(define fact-prog
  '((define i64 (@fact (i64 %n))
      (label %entry
        (= %isbase (icmp slt i64 %n 2))
        (br i1 %isbase (label %base) (label %rec)))
      (label %base
        (ret i64 1))
      (label %rec
        (= %n1 (sub i64 %n 1))
        (= %f (call i64 (@fact (i64 %n1))))
        (= %r (mul i64 %n %f))
        (ret i64 %r)))))

(printf "=== the sll program, transliterated to LLVM IR ===~%~a~%"
        (sll:dump fact-prog))

(define fact (sll:procedure fact-prog "fact"))

(printf "=== calling the JIT'd code ===~%")
(do ([i 0 (+ i 1)])
    ((> i 10))
  (printf "fact(~a) = ~a~%" i (fact i)))
(printf "fact(20) = ~a~%" (fact 20))
