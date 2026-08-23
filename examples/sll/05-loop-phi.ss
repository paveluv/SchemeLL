;;; A counted loop written the SSA way: phi nodes carry the loop state.
;;; Note the (value %label) incoming pairs and that phis may reference
;;; blocks defined later.
(import (chezscheme) (prefix (sll) sll:))

(define sum-to
  (sll:procedure
    '((define i64 (@sum_to (i64 %n))
        (label %entry (br (label %loop)))
        (label %loop
          (= %i   (phi i64 (1 %entry) (%i1 %loop)))
          (= %acc (phi i64 (0 %entry) (%acc1 %loop)))
          (= %acc1 (add i64 %acc %i))
          (= %i1 (add i64 %i 1))
          (= %done (icmp sgt i64 %i1 %n))
          (br i1 %done (label %exit) (label %loop)))
        (label %exit (ret i64 %acc1))))
    "sum_to"))

(printf "1+2+...+100 = ~a~%" (sum-to 100))
