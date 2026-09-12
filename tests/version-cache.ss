;;; The installed releases; compile config/raw once and reuse those Chez objects
;;; in fresh 20/19/16/20 processes. Original source caches are untouched.
(load "host/bootstrap.ss")
(import (chezscheme) (prefix (llvm host-command-line) host:))
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
     "~a --libdirs ~a --script tests/version-cache.ss --llvm ~a --chez ~a ~a"
     (q (host:chez-command))
     (q (string-append cache ":."))
     major
     (q (host:chez-command))
     mode]]]
  (error 'version-cache "child failed" major mode)]]
[case
 [and
  (pair? (host:remaining-arguments))
  (string->symbol (car (host:remaining-arguments)))]
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
      '(prefix (llvm config) config:)
      '(prefix (llvm host-command-line) host:)]]]
   [eval
    '[begin
      [unless
       (= config:major-version (host:option-major))
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
   (host:option-prefix)
   [error
    'version-cache
    "the matrix needs the conventional installations; drop --llvm-prefix"]]
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
  (for-each (lambda (major) (run major "probe")) '(20 19 16 20))]]
