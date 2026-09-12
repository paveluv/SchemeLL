;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; Constant expressions: link-time address arithmetic in initializers.
(import (chezscheme) (prefix (sll) sll:))

[define
 prog
 '[(= @table (global (array 4 i64) ((i64 10) (i64 20) (i64 30) (i64 40))))
   ;; a pointer INTO the table, computed at compile time
   [=
    @third
    [global
     ptr
     (getelementptr inbounds (array 4 i64) (ptr @table) (i64 0) (i64 2))]]
   [define
    i64
    (@read_third)
    [label
     %entry
     (= %p (load ptr (ptr @third)))
     (= %v (load i64 (ptr %p)))
     (ret i64 %v)]]]]

(define read-third (sll:procedure prog "read_third"))
(printf "*@third = ~a~%" (read-third))
