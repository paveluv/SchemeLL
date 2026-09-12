;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; Emit native assembly text and show it.
[import
 (chezscheme)
 (prefix (sll) sll:)
 (prefix (llvm ir) ir:)
 (prefix (llvm target) target:)]

(define ctx (ir:make-context))
[define
 m
 [sll:build
  ctx
  "abs"
  '[[define
     i64
     (@iabs (i64 %x))
     [label
      %entry
      (= %neg (icmp slt i64 %x 0))
      (= %minus (sub i64 0 %x))
      (= %r (select (i1 %neg) (i64 %minus) (i64 %x)))
      (ret i64 %r)]]]]]

(target:initialize-native!)
(define tm (target:make-machine))
(target:configure-module! m tm)
(ir:run-module-passes! m "default<O2>")
(target:emit-assembly-file tm m "/tmp/iabs.s")
(display (call-with-input-file "/tmp/iabs.s" get-string-all))
