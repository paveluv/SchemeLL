;;; Object code without touching the filesystem: emit to a bytevector.
(import (chezscheme) (prefix (llvm ir) ir:) (prefix (llvm target) target:))

(define ctx (ir:make-context))

[define
 m
 [ir:parse-ir
  ctx
  "obj"
  "
define i64 @add(i64 %a, i64 %b) {
entry:
  %s = add i64 %a, %b
  ret i64 %s
}"]]

(target:initialize-native!)

(define tm (target:make-machine))

(target:configure-module! m tm)

(define bytes (target:emit-object-bytevector tm m))

[printf
 "emitted a ~a-byte relocatable object (ELF magic: ~x ~c~c~c)~%"
 (bytevector-length bytes)
 (bytevector-u8-ref bytes 0)
 (integer->char (bytevector-u8-ref bytes 1))
 (integer->char (bytevector-u8-ref bytes 2))
 (integer->char (bytevector-u8-ref bytes 3))]
