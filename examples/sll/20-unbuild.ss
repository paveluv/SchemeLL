;;; The round trip: build a module, read it BACK into sll data with
;;; sll:unbuild, and print it as textual LLVM IR with the pure-Scheme
;;; renderer -- no LLVM involved in that last step.
(import (chezscheme)
        (prefix (sll) sll:)
        (prefix (sll render) render:)
        (prefix (llvm ir) ir:))

(define prog
  '((define i64 (@triple (i64 %x))
      (label %entry
        (= %t (mul nsw i64 %x 3))
        (ret i64 %t)))))

(define ctx (ir:make-context))
(define m (sll:build ctx "demo" prog))

(printf "=== unbuild: module -> sll data ===~%")
(write (sll:unbuild m))
(newline)

(printf "~%=== render: sll data -> textual IR, in pure Scheme ===~%")
(display (render:sll->ll (sll:unbuild m)))
