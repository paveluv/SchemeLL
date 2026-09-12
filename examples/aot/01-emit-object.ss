;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; AOT from a script: build an sll program and write a relocatable object --
;;; the LLVM API does the codegen, no external tools.
[import
 (chezscheme)
 (prefix (sll) sll:)
 (prefix (llvm ir) ir:)
 (prefix (llvm target) target:)]

[define
 prog
 '[[define
    i64
    (@square (i64 %x))
    (label %entry (= %r (mul nsw i64 %x %x)) (ret i64 %r))]]]

(define ctx (ir:make-context))
(define m (sll:build ctx "square" prog))
(ir:verify-module m)

(target:initialize-native!)
(define tm (target:make-machine))
(target:configure-module! m tm)
(target:emit-object-file tm m "/tmp/square.o")
(printf "wrote /tmp/square.o for ~a~%" (target:default-triple))
