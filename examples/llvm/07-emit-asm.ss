;;; Native assembly text for the host target.
(import (chezscheme) (prefix (llvm ir) ir:) (prefix (llvm target) target:))

(define ctx (ir:make-context))
(define m (ir:parse-ir ctx "asm" "
define i64 @twice(i64 %x) {
entry:
  %r = shl i64 %x, 1
  ret i64 %r
}"))

(target:initialize-native!)
(define tm (target:make-machine))
(target:configure-module! m tm)
(target:emit-assembly-file tm m "/tmp/sll-example.s")
(printf "~a" (call-with-input-file "/tmp/sll-example.s" get-string-all))
