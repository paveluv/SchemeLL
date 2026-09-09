;;; The safety layer: (llvm ir) tracks ownership, so use-after-dispose raises a
;;; Scheme error instead of segfaulting the process.
(import (chezscheme) (prefix (llvm ir) ir:))

(define ctx (ir:make-context))

(define m (ir:make-module ctx "owned"))

(printf "module alive: ~s~%" (ir:module? m))

(ir:module-dispose! m)

[guard
 [e
  [#t
   [printf
    "after dispose, module->string raised:~%  ~a~%"
    (condition-message e)]]]
 (ir:module->string m)]

(ir:context-dispose! ctx)

[guard
 [e
  [#t
   [printf
    "after context dispose, make-module raised:~%  ~a~%"
    (condition-message e)]]]
 (ir:make-module ctx "zombie")]
