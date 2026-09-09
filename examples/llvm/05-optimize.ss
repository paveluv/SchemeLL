;;; The new pass manager: run an O2 pipeline over a module and watch the IR
;;; collapse.
(import (chezscheme) (prefix (llvm ir) ir:) (prefix (llvm target) target:))

(define ctx (ir:make-context))
[define
 m
 [ir:parse-ir
  ctx
  "opt"
  "
define i64 @silly(i64 %x) {
entry:
  %a = add i64 %x, 0
  %b = mul i64 %a, 1
  %c = add i64 %b, 21
  %d = add i64 %c, 21
  br label %next
next:
  ret i64 %d
}"]]

(printf "=== before ===~%~a~%" (ir:module->string m))
(target:initialize-native!)
(ir:run-module-passes! m "default<O2>")
(printf "=== after default<O2> ===~%~a" (ir:module->string m))
