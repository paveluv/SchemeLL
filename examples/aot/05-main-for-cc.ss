;;; A complete main.o that calls libc printf: everything up to the final link
;;; happens through the LLVM API. (Linking against libc is the system linker's
;;; job; the flagship zero-tool executable is hello.sll + sllc --exe, which
;;; avoids libc entirely.)
[import
 (chezscheme)
 (prefix (sll) sll:)
 (prefix (llvm ir) ir:)
 (prefix (llvm target) target:)]

[define
 prog
 '[(= @fmt (constant (array 20 i8) (cz "6 * 7 = %ld from .o")))
   (declare i32 (@printf ptr variadic))
   [define
    i32
    (@main)
    [label
     %entry
     (= %r (call (fn i32 ptr variadic) (@printf (ptr @fmt) (i64 42))))
     (ret i32 0)]]]]

(define ctx (ir:make-context))
(define m (sll:build ctx "main" prog))
(ir:verify-module m)
(target:initialize-native!)
(define tm (target:make-machine))
(target:configure-module! m tm)
(target:emit-object-file tm m "/tmp/sll-main.o")
(printf "wrote /tmp/sll-main.o -- link with: cc /tmp/sll-main.o -o demo~%")
