;;; Two installed releases; compile config/raw once and reuse those Chez objects
;;; in fresh 20/19/20 processes. Original source caches are untouched.
(load "host/bootstrap.ss")
(import (chezscheme))
(define cache "tests/tmp/version-cache")
[define
 (q s)
 [string-append
  "'"
  [apply
   string-append
   (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list s))]
  "'"]]
[define
 (run major mode)
 [unless
  [zero?
   [system
    [format
     "SCHEMELL_LLVM_VERSION=~a ~a --libdirs ~a --script tests/version-cache.ss ~a"
     major
     (q (or (getenv "CHEZ") "scheme"))
     (q (string-append cache ":."))
     mode]]]
  (error 'version-cache "child failed" major mode)]]
[case
 (and (pair? (cdr (command-line))) (string->symbol (cadr (command-line))))
 [(compile)
  (compile-library (string-append cache "/llvm/selection.sls"))
  (compile-library (string-append cache "/llvm/config.sls"))
  (compile-library (string-append cache "/llvm/raw.sls"))]
 [(probe)
  [let
   [[env
     [environment
      '(chezscheme)
      '(prefix (sll) sll:)
      '(prefix (llvm config) config:)]]]
   [eval
    '[begin
      [unless
       [=
        config:major-version
        (string->number (getenv "SCHEMELL_LLVM_VERSION"))]
       (error 'version-cache "cached selection")]
      [unless
       [=
        42
        [[sll:procedure
          '((define i64 (@answer) (label %entry (ret i64 42))))
          "answer"]]]
       (error 'version-cache "wrong JIT answer")]
      (printf "compiled bindings: LLVM ~s, answer 42\n" (config:version))]
    env]]]
 [else
  [when
   (getenv "SCHEMELL_LLVM_PREFIX")
   [error
    'version-cache
    "matrix needs default installations; unset SCHEMELL_LLVM_PREFIX"]]
  [for-each
   (lambda (p) (unless (file-exists? p) (mkdir p)))
   (list "tests/tmp" cache (string-append cache "/llvm"))]
  [for-each
   [lambda
    (name)
    [let
     [[data
       [call-with-port
        (open-file-input-port (string-append "llvm/" name))
        get-bytevector-all]]]
     [call-with-port
      [open-file-output-port
       (string-append cache "/llvm/" name)
       (file-options no-fail)]
      (lambda (p) (put-bytevector p data))]]]
   '("selection.sls" "config.sls" "raw.sls")]
  (run 19 "compile")
  (for-each (lambda (major) (run major "probe")) '(20 19 20))]]
