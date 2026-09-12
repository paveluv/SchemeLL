;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; Global byte-string constants and libc puts: hello, world.
(import (chezscheme) (prefix (sll) sll:))

[define
 hello
 [sll:procedure
  '[(= @msg (constant (array 14 i8) (cz "hello, world!")))
    (declare i32 (@puts ptr))
    [define
     i32
     (@hello)
     (label %entry (= %r (call i32 (@puts (ptr @msg)))) (ret i32 %r))]]
  "hello"]]

(hello)
