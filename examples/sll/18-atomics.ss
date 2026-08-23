;;; Atomic operations: atomicrmw, cmpxchg, and fences with orderings.
(import (chezscheme) (prefix (sll) sll:))

(define prog
  '((= @slot (global i64 100))
    (define i64 (@fetch_add (i64 %by))
      (label %entry
        (= %old (atomicrmw add (ptr @slot) (i64 %by) seq_cst))
        (ret i64 %old)))
    (define i64 (@try_swap (i64 %expect) (i64 %new))
      (label %entry
        (= %pair (cmpxchg (ptr @slot) (i64 %expect) (i64 %new)
                          seq_cst monotonic))
        (fence acquire)
        (= %ok (extractvalue ((struct i64 i1) %pair) 1))
        (= %r (zext i1 %ok i64))
        (ret i64 %r)))))

(define fetch-add (sll:procedure prog "fetch_add"))
(printf "fetch-add 5 -> old value ~a~%" (fetch-add 5))
(printf "fetch-add 0 -> now ~a~%" (fetch-add 0))
