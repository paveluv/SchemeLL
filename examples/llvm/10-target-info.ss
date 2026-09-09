;;; Host target facts: triple, CPU, features -- what the JIT and the object
;;; emitter configure modules with.
(import (chezscheme) (prefix (llvm target) target:))

(target:initialize-native!)

(printf "default triple: ~a~%" (target:default-triple))

(printf "host cpu:       ~a~%" (target:host-cpu-name))

[let
 ((feats (target:host-cpu-features)))
 [printf
  "features:       ~a...~%"
  (substring feats 0 (min 60 (string-length feats)))]]
