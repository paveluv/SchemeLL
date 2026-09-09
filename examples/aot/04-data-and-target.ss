;;; A library object with global data; the triple and datalayout are ordinary
;;; sll items, so the .o is reproducible bit-for-bit.
[import
 (chezscheme)
 (prefix (sll) sll:)
 (prefix (llvm ir) ir:)
 (prefix (llvm target) target:)]

[define
 prog
 '[(= @greeting (constant (array 6 i8) (cz "hello")))
   (= @version (constant i32 3))
   (define ptr (@get_greeting) (label %entry (ret ptr @greeting)))
   [define
    i32
    (@get_version)
    (label %entry (= %v (load i32 (ptr @version))) (ret i32 %v))]]]

(define ctx (ir:make-context))
(define m (sll:build ctx "libgreet" prog))
(target:initialize-native!)
(define tm (target:make-machine))
(target:configure-module! m tm)
(target:emit-object-file tm m "/tmp/libgreet.o")
(printf "wrote /tmp/libgreet.o (data + code sections)~%")
