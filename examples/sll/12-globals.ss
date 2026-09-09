;;; Mutable global state living inside the JIT'd module.
(import (chezscheme) (prefix (sll) sll:))

[define
 bump
 [sll:procedure
  '[(= @counter (global i64 0))
    [define
     i64
     (@bump (i64 %by))
     [label
      %entry
      (= %old (load i64 (ptr @counter)))
      (= %new (add i64 %old %by))
      (store (i64 %new) (ptr @counter))
      (ret i64 %new)]]]
  "bump"]]

(printf "bump 5  -> ~a~%" (bump 5))

(printf "bump 10 -> ~a~%" (bump 10))

(printf "bump 1  -> ~a~%" (bump 1))
