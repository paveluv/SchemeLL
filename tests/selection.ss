#!chezscheme
;;; Pure selection: requirements, candidates, explicit pins and sealing, all
;;; before loading any C code. Resolution against real installations is
;;; exercised in fresh processes by tests/test-version.ss.
[import
 (chezscheme)
 (prefix (llvm selection) s:)
 (prefix (llvm host-command-line) host:)]
(define checks 0)
[define
 (check label value)
 (unless value (error 'selection-test label))
 (set! checks (+ checks 1))]
(define (refuses thunk) (guard (e (else #t)) (thunk) #f))
(check "imports are LLVM-free" (not (foreign-entry? "LLVMGetVersion")))
[check
 "the default major is unresolved (#f), not a fixed release"
 (not (s:selection-ref (s:make-selection '()) 'major-version))]
[check
 "the preference order names qualified majors, 19 first"
 [and
  (equal? s:preference '(19 20 16))
  (for-all (lambda (m) (memv m s:qualified-majors)) s:preference)
  (equal? (map car s:qualified-versions) '(16 19 20))]]
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
[check
 "capabilities are per release"
 [and
  (s:capability-of 16 'typed-pointers)
  (not (s:capability-of 19 'typed-pointers))
  (s:capability-of 19 'x86-mmx)
  (not (s:capability-of 20 'x86-mmx))
  (s:capability-of 20 'atomic-usub)
  (not (s:capability-of 19 'atomic-usub))
  (memq 'callbr s:capability-names)]]
[check
 "an unknown capability is refused"
 (refuses (lambda () (s:capability-of 19 'no-such-thing)))]
[check
 "no requirements: the candidates are the preference order"
 (equal? (s:candidates) s:preference)]
[check
 "requiring an unknown capability is refused"
 (refuses (lambda () (s:require! 'no-such-thing)))]
[check
 "preferring an unknown capability is refused"
 (refuses (lambda () (s:prefer! 'no-such-thing)))]
(s:prefer! 'typed-pointers)
[check
 "a preference reorders the candidates without excluding any"
 [and
  (equal? (s:preferences) '(typed-pointers))
  (equal? (s:candidates) '(16 19 20))]]
(s:require! 'typed-pointers)
[check
 "a requirement narrows the candidates"
 [and
  (equal? (s:requirements) '(typed-pointers))
  (equal? (s:candidates) '(16))]]
(s:prefer! 'callbr)
[check
 "a preference no candidate satisfies changes nothing"
 (equal? (s:candidates) '(16))]
[check
 "an explicit release that lacks a requirement is refused"
 (refuses (lambda () (s:select! (s:make-selection '((major-version . 19))))))]
(define path (string-copy "/explicit/libLLVM.so"))
[define
 selection
 (s:make-selection (list (cons 'major-version 16) (cons 'shared-object path)))]
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
 "the command-line adapter leaves an explicit selection alone"
 (and (= 16 (s:selection-ref selection 'major-version)) (not (s:sealed?)))]
[check
 "the command-line adapter reads nothing when no option was given"
 [and
  (not (host:option-major))
  (not (host:option-prefix))
  (equal? (host:chez-command) "scheme")]]
[check
 "resolution honors the explicit release and seals"
 (and (= 16 (s:resolve! (lambda (major) #f))) (s:sealed?))]
[check
 "a requirement the sealed release has is accepted"
 (begin (s:require! 'typed-pointers) #t)]
[check
 "a requirement the sealed release lacks is refused"
 (refuses (lambda () (s:require! 'callbr)))]
[s:select!
 [s:make-selection
  '[(major-version . 16                    )
    (shared-object . "/explicit/libLLVM.so")]]]
[check
 "changing a sealed installation is refused"
 (refuses (lambda () (s:select! (s:make-selection '((major-version . 19))))))]
[check
 "validation and sealing did not load LLVM"
 (not (foreign-entry? "LLVMGetVersion"))]

;; The invariant behind all of this: no library source reads the environment.
;; Walk every library's source as data and look for getenv/putenv.
[define
 (source-mentions? path names)
 [let
  ((p (open-input-file path)))
  [let
   loop
   ()
   [let
    ((form (read p)))
    [cond
     ((eof-object? form) (close-port p) #f)
     [[let
       walk
       ((x form))
       [cond
        ((symbol? x) (and (memq x names) #t))
        ((pair? x) (or (walk (car x)) (walk (cdr x))))
        (else #f)]]
      (close-port p)
      #t]
     (else (loop))]]]]]
[define
 library-sources
 [append
  (map (lambda (f) (string-append "llvm/" f)) (directory-list "llvm"))
  (map (lambda (f) (string-append "sll/" f)) (directory-list "sll"))
  '("sll.sls")]]
[check
 "no library source reads or writes the environment"
 [for-all
  (lambda (path) (not (source-mentions? path '(getenv putenv))))
  [filter
   [lambda
    (p)
    [let
     ((n (string-length p)))
     (and (> n 4) (string=? ".sls" (substring p (- n 4) n)))]]
   library-sources]]]
(printf "~a pure LLVM selection checks passed\n" checks)
