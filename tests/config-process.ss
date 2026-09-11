;;; Fresh-process configuration boundary. Used by test-version.ss.
(import (chezscheme))
[guard
 (e (else (display-condition e) (newline) (exit 1)))
 [when
  (string=? (cadr (command-line)) "preload")
  (load-shared-object (caddr (command-line)))]
 [let
  ((env (environment '(chezscheme) '(prefix (llvm config) config:))))
  (write (eval '(config:version) env))
  [when
   (string=? (cadr (command-line)) "headers")
   (write (eval '(config:validate-headers!) env))]
  (newline)]]
