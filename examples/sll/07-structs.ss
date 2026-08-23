;;; Named struct types, getelementptr field access, insert/extractvalue.
(import (chezscheme) (prefix (sll) sll:))

(define prog
  '((type %point (struct i64 i64))
    (define i64 (@manhattan (ptr %p))
      (label %entry
        (= %xp (getelementptr %point (ptr %p) (i64 0) (i32 0)))
        (= %yp (getelementptr %point (ptr %p) (i64 0) (i32 1)))
        (= %x (load i64 (ptr %xp)))
        (= %y (load i64 (ptr %yp)))
        (= %s (add i64 %x %y))
        (ret i64 %s)))
    ;; the same struct as a first-class VALUE, via insert/extractvalue
    (define i64 (@diag (i64 %n))
      (label %entry
        (= %p0 (insertvalue (%point undef) (i64 %n) 0))
        (= %p  (insertvalue (%point %p0) (i64 %n) 1))
        (= %x (extractvalue (%point %p) 0))
        (= %y (extractvalue (%point %p) 1))
        (= %s (add i64 %x %y))
        (ret i64 %s)))))

(define diag (sll:procedure prog "diag"))
(printf "diag(21) = ~a~%" (diag 21))
