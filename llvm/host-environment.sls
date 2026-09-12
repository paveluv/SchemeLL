;;; Optional hosted command adapter. Importing this library reads nothing.
[library
 (llvm host-environment)
 (export install! selection-from-reader)
 (import (chezscheme) (prefix (llvm selection) selection:))
 [define
  (selection-from-reader read-variable)
  [let
   [(major (read-variable "SCHEMELL_LLVM_VERSION"))
    (prefix (read-variable "SCHEMELL_LLVM_PREFIX"))]
   [selection:make-selection
    [append
     [if
      major
      [list
       [cons
        'major-version
        [cond
         ((string=? major "16") 16)
         ((string=? major "19") 19)
         ((string=? major "20") 20)
         [else
          [error
           'llvm-environment
           "unsupported SCHEMELL_LLVM_VERSION; expected 16, 19 or 20"
           major]]]]]
      '()]
     [if
      (and prefix (not (string=? prefix "")))
      (list (cons 'prefix prefix))
      '()]]]]]
 [define
  (install!)
  [unless
   (selection:selected?)
   (selection:select! (selection-from-reader getenv))]]]
