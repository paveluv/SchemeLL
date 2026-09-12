;;; Optional hosted command input: an LLVM release named on the command line.
;;; Importing this library reads nothing; install! parses (command-line) for
;;;   --llvm N             select the qualified major N
;;;   --llvm-prefix DIR    an installation directory with lib/ and include/
;;;   --chez PATH          the Chez binary child processes should run
;;; and installs a selection unless one exists already (an explicit Scheme
;;; selection wins). remaining-arguments is the command line without those
;;; options, for scripts that parse their own.
[library
 (llvm host-command-line)
 (export install! remaining-arguments option-major option-prefix chez-command)
 (import (chezscheme) (prefix (llvm selection) selection:))

 ;; -> (values major prefix chez remaining)
 [define
  (parse args)
  [let
   loop
   ((args args) (major #f) (prefix #f) (chez #f) (rest '()))
   [cond
    ((null? args) (values major prefix chez (reverse rest)))
    [(string=? (car args) "--llvm")
     (when (null? (cdr args)) (error 'host-command-line "--llvm needs a value"))
     [let
      ((n (string->number (cadr args))))
      [unless
       (memv n selection:qualified-majors)
       [error
        'host-command-line
        [format
         "unsupported --llvm; expected one of ~a"
         selection:qualified-majors]
        (cadr args)]]
      (loop (cddr args) n prefix chez rest)]]
    [(string=? (car args) "--llvm-prefix")
     [when
      (or (null? (cdr args)) (string=? (cadr args) ""))
      (error 'host-command-line "--llvm-prefix needs a directory")]
     (loop (cddr args) major (cadr args) chez rest)]
    [(string=? (car args) "--chez")
     (when (null? (cdr args)) (error 'host-command-line "--chez needs a path"))
     (loop (cddr args) major prefix (cadr args) rest)]
    (else (loop (cdr args) major prefix chez (cons (car args) rest)))]]]

 (define (arguments) (cdr (command-line)))

 [define
  (option-major)
  (let-values (((major prefix chez rest) (parse (arguments)))) major)]
 [define
  (option-prefix)
  (let-values (((major prefix chez rest) (parse (arguments)))) prefix)]
 [define
  (remaining-arguments)
  (let-values (((major prefix chez rest) (parse (arguments)))) rest)]
 ;; the Chez binary to run children with: --chez, else "scheme"
 [define
  (chez-command)
  [let-values
   (((major prefix chez rest) (parse (arguments))))
   (or chez "scheme")]]

 [define
  (install!)
  [unless
   (selection:selected?)
   [let-values
    (((major prefix chez rest) (parse (arguments))))
    [when
     (or major prefix)
     [selection:select!
      [selection:make-selection
       [append
        (if major (list (cons 'major-version major)) '())
        (if prefix (list (cons 'prefix prefix)) '())]]]]]]]]
