#!chezscheme
;;; Pure selection can be configured and validated before loading any C code.
[import
 (chezscheme)
 (prefix (llvm selection) s:)
 (prefix (llvm host-environment) host:)]
(define checks 0)
[define
 (check label value)
 (unless value (error 'selection-test label))
 (set! checks (+ checks 1))]
(define (refuses thunk) (guard (e (else #t)) (thunk) #f))
(check "imports are LLVM-free" (not (foreign-entry? "LLVMGetVersion")))
[check
 "default is LLVM 19"
 (= 19 (s:selection-ref (s:make-selection '()) 'major-version))]
[check
 "16 and 20 are qualified majors"
 [and
  [=
   16
   (s:selection-ref (s:make-selection '((major-version . 16))) 'major-version)]
  [=
   20
   [s:selection-ref
    (s:make-selection '((major-version . 20)))
    'major-version]]]]
[for-each
 [lambda
  (entries)
  [check
   "invalid selection must be refused"
   (refuses (lambda () (s:make-selection entries)))]]
 '[((typo . 1))
   ((major-version . "20"))
   ((major-version . 21))
   ((major-version . 19) (major-version . 20))
   ((prefix . ""))
   ((shared-object . 7))]]
(define path (string-copy "/explicit/libLLVM.so"))
[define
 selection
 (s:make-selection (list (cons 'major-version 20) (cons 'shared-object path)))]
(string-set! path 0 #\x)
(string-set! (s:selection-ref selection 'shared-object) 0 #\y)
[check
 "strings are copied"
 (string=? "/explicit/libLLVM.so" (s:selection-ref selection 'shared-object))]
(s:select! selection)
[check
 "explicit selection is installed before it is consumed"
 (and (s:selected?) (not (s:sealed?)))]
(host:install!)
[check
 "explicit selection wins over environment adapter"
 (= 20 (s:setting 'major-version))]
(check "first consumption seals the selection" (s:sealed?))
[s:select!
 [s:make-selection
  '[(major-version . 20                    )
    (shared-object . "/explicit/libLLVM.so")]]]
[check
 "changing a sealed installation is refused"
 (refuses (lambda () (s:select! (s:make-selection '((major-version . 19))))))]
[check
 "validation and sealing did not load LLVM"
 (not (foreign-entry? "LLVMGetVersion"))]
(printf "~a pure LLVM selection checks passed\n" checks)
