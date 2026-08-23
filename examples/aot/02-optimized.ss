;;; Optimize before emitting: the same pipeline clang -O2 runs.
(import (chezscheme)
        (prefix (sll) sll:)
        (prefix (llvm ir) ir:)
        (prefix (llvm target) target:))

(define prog
  '((define i64 (@sum_squares (i64 %n))     ; naive loop, O2 will improve it
      (label %entry (br (label %loop)))
      (label %loop
        (= %i (phi i64 (1 %entry) (%i1 %loop)))
        (= %acc (phi i64 (0 %entry) (%acc1 %loop)))
        (= %sq (mul i64 %i %i))
        (= %acc1 (add i64 %acc %sq))
        (= %i1 (add i64 %i 1))
        (= %done (icmp sgt i64 %i1 %n))
        (br i1 %done (label %exit) (label %loop)))
      (label %exit (ret i64 %acc1)))))

(define ctx (ir:make-context))
(define m (sll:build ctx "sums" prog))
(target:initialize-native!)
(define tm (target:make-machine))
(target:configure-module! m tm)
(ir:run-module-passes! m "default<O2>")
(printf "=== optimized IR ===~%~a~%" (ir:module->string m))
(target:emit-object-file tm m "/tmp/sums.o")
(printf "wrote /tmp/sums.o~%")
