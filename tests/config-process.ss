;;; Fresh-process configuration boundary. Used by test-version.ss.
;;;   config-process.ss [--llvm N] [--llvm-prefix DIR] MODE [ARG]
;;;   MODE: version | headers | preload SHARED-OBJECT | scheme-N (select N in
;;;   Scheme first) | require CAP[,CAP...] (require! before the adapter runs)
(import (chezscheme) (prefix (llvm host-command-line) host:))
[guard
 (e (else (display-condition e) (newline) (exit 1)))
 [let*
  [(rest (host:remaining-arguments))
   (mode (car rest))
   (arg (and (pair? (cdr rest)) (cadr rest)))
   (env (environment '(chezscheme) '(prefix (llvm selection) selection:)))]
  [when
   (and (> (string-length mode) 7) (string=? (substring mode 0 7) "scheme-"))
   [eval
    `[selection:select!
      [selection:make-selection
       '[[major-version
          .
          ,(string->number (substring mode 7 (string-length mode)))]]]]
    env]]
  [when
   (string=? mode "require")
   [let
    split
    ((chars (string->list arg)) (cur '()) (names '()))
    [cond
     [(null? chars)
      [eval
       `[selection:require!
         ,@[map
            (lambda (s) `',(string->symbol s))
            (reverse (cons (list->string (reverse cur)) names))]]
       env]]
     [(char=? (car chars) #\,)
      (split (cdr chars) '() (cons (list->string (reverse cur)) names))]
     (else (split (cdr chars) (cons (car chars) cur) names))]]]
  (load "host/bootstrap.ss")
  (when (string=? mode "preload") (load-shared-object arg))
  [let
   ((cenv (environment '(chezscheme) '(prefix (llvm config) config:))))
   (write (eval '(config:version) cenv))
   [when
    (string=? mode "headers")
    (write (eval '(config:validate-headers!) cenv))]
   (newline)]]]
