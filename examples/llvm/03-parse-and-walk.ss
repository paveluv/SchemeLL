;;; Introspection: parse textual IR and walk the object model --
;;; functions, blocks, instructions, opcodes.
(import (chezscheme) (prefix (llvm ir) ir:))

(define ctx (ir:make-context))
(define m (ir:parse-ir ctx "walk" "
define i64 @gcd(i64 %a, i64 %b) {
entry:
  br label %loop
loop:
  %x = phi i64 [ %a, %entry ], [ %y, %loop ]
  %y = phi i64 [ %b, %entry ], [ %r, %loop ]
  %r = srem i64 %x, %y
  %done = icmp eq i64 %r, 0
  br i1 %done, label %exit, label %loop
exit:
  ret i64 %y
}"))

(for-each
  (lambda (f)
    (printf "function ~a: ~a blocks~%"
            (ir:value-name f) (length (ir:function-blocks f)))
    (for-each
      (lambda (bb)
        (printf "  block with ~a instructions; opcodes:"
                (length (ir:block-instructions bb)))
        (for-each (lambda (i) (printf " ~a" (ir:instruction-opcode i)))
                  (ir:block-instructions bb))
        (newline))
      (ir:function-blocks f)))
  (ir:module-functions m))
