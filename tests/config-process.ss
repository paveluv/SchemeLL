;;; Fresh-process configuration boundary. Used by test-version.ss.
(import (chezscheme))
[guard
 (e (else (display-condition e) (newline) (exit 1)))
 [when
  (member (cadr (command-line)) '("scheme-19" "scheme-20"))
  [let
   ((env (environment '(chezscheme) '(prefix (llvm selection) selection:))))
   [eval
    `[selection:select!
      [selection:make-selection
       '[[major-version
          .
          ,(if (string=? (cadr (command-line)) "scheme-19") 19 20)]]]]
    env]]]
 (load "host/bootstrap.ss")
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
