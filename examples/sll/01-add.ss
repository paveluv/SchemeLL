;;; The smallest possible sll program: one import, one function, one call.
(import (chezscheme) (prefix (sll) sll:))

(define add
  (sll:procedure
    '((define i64 (@add (i64 %a) (i64 %b))
        (label %entry
          (= %sum (add i64 %a %b))
          (ret i64 %sum))))
    "add"))

(printf "2 + 40 = ~a~%" (add 2 40))
