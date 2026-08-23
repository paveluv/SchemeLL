;;; Aggregate constants: arrays of structs as global data, walked by
;;; index computed at run time.
(import (chezscheme) (prefix (sll) sll:))

(define prog
  '((type %entry (struct i64 i64))               ; (key, value)
    (= @kv (constant (array 3 %entry)
                     ((%entry ((i64 1) (i64 100)))
                      (%entry ((i64 2) (i64 200)))
                      (%entry ((i64 3) (i64 300))))))
    (define i64 (@lookup (i64 %i))
      (label %entry
        (= %vp (getelementptr (array 3 %entry) (ptr @kv)
                              (i64 0) (i64 %i) (i32 1)))
        (= %v (load i64 (ptr %vp)))
        (ret i64 %v)))))

(define lookup (sll:procedure prog "lookup"))
(do ([i 0 (+ i 1)]) ((> i 2))
  (printf "kv[~a].value = ~a~%" i (lookup i)))
