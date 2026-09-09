;;; Stack memory: alloca, store, load -- with explicit alignment.
(import (chezscheme) (prefix (sll) sll:))

[define
 swap-halves
 [sll:procedure
  '[[define
     i64
     (@swap_halves (i64 %x))
     [label
      %entry
      (= %slot (alloca i64 (align 8)))
      (store (i64 %x) (ptr %slot) (align 8))
      (= %lo32p (getelementptr i32 (ptr %slot) (i64 0)))
      (= %hi32p (getelementptr i32 (ptr %slot) (i64 1)))
      (= %lo (load i32 (ptr %lo32p)))
      (= %hi (load i32 (ptr %hi32p)))
      (store (i32 %hi) (ptr %lo32p))
      (store (i32 %lo) (ptr %hi32p))
      (= %r (load i64 (ptr %slot) (align 8)))
      (ret i64 %r)]]]
  "swap_halves"]]

[printf
 "swap-halves(#x1111111122222222) = ~x~%"
 (swap-halves #x1111111122222222)]
