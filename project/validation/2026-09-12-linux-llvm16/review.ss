#!chezscheme
;;; Focused review of 07cfbb0. Run from the repository root with the selected
;;; LLVM release. The initial failures are retained in review-before-llvm16.log;
;;; the repaired implementation passes. The main suite adds broader coverage.
(load "host/bootstrap.ss")
[import
 (chezscheme)
 (prefix (llvm ir) ir:)
 (prefix (llvm config) config:)
 (prefix (sll) sll:)
 (prefix (tests normalize) n:)
 (prefix (tests harness) t:)]

[define
 (shell-quote s)
 [string-append
  "'"
  [apply
   string-append
   (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list s))]
  "'"]]

[define
 (contains? text part)
 [let
  loop
  ((i 0))
  [and
   (<= (+ i (string-length part)) (string-length text))
   [or
    (string=? part (substring text i (+ i (string-length part))))
    (loop (+ i 1))]]]]

[define
 (with-module name text action)
 [let*
  ((ctx (ir:make-context)) (m (ir:parse-ir ctx name text)))
  [dynamic-wind
   void
   (lambda () (ir:verify-module m) (action m))
   (lambda () (ir:module-dispose! m) (ir:context-dispose! ctx))]]]

[define
 (rebuilt-text m)
 [let
  ((program (sll:unbuild m)) (ctx (ir:make-context)))
  [dynamic-wind
   void
   [lambda
    ()
    [let
     ((rebuilt (sll:build ctx "rebuilt" program)))
     [dynamic-wind
      void
      (lambda () (ir:verify-module rebuilt) (ir:module->string rebuilt))
      (lambda () (ir:module-dispose! rebuilt))]]]
   (lambda () (ir:context-dispose! ctx))]]]

[define
 (refused? m reason)
 [guard
  [e
   [[and
     (who-condition? e)
     (eq? (condition-who e) 'sll:unbuild)
     (message-condition? e)
     (contains? (condition-message e) "not modeled")
     (contains? (condition-message e) reason)]
    #t]]
  [let
   ((after (rebuilt-text m)))
   [printf
    "Unexpected successful round trip. Before:\n~aAfter:\n~a"
    (ir:module->string m)
    after]
   #f]]]

[define
 (roundtrips? m)
 [string=?
  (n:comparable-ir (ir:module->string m))
  (n:comparable-ir (rebuilt-text m))]]

(printf "Reviewing LLVM ~s on ~s\n" (config:version) (machine-type))
(t:section "operand bundle detection")
[for-each
 [lambda
  (attributes)
  [t:check
   [string-append
    "bundles preserved or explicitly refused; attributes="
    attributes]
   [with-module
    "bundle"
    [string-append
     "declare void @g()\ndefine void @f() {\nentry:\n call void @g() "
     attributes
     "[ \"deopt\"(i32 7) ]\n ret void\n}\n"]
    [lambda
     (m)
     [if
      (config:capability? 'operand-bundles)
      (roundtrips? m)
      (refused? m "operand bundles")]]]]]
 '("" "nounwind ")]

(t:section "function prefix and prologue detection")
[for-each
 [lambda
  (entry)
  [t:check
   (car entry)
   [with-module
    (car entry)
    (cadr entry)
    (lambda (m) (refused? m (caddr entry)))]]]
 '[["prefix after function attribute comment"
    "define i32 @f() nounwind prefix i32 123 {\nentry:\n ret i32 42\n}\n"
    "function prefix data"]
   ["prefix after literal struct return type"
    "define {i32, i32} @f() prefix i32 123 {\nentry:\n ret {i32, i32} zeroinitializer\n}\n"
    "function prefix data"]
   ["prologue after function attribute comment"
    "define i32 @f() nounwind prologue i32 123 {\nentry:\n ret i32 42\n}\n"
    "function prologue data"]]]
[t:check
 "quoted function name is not prefix data"
 [with-module
  "quoted-name"
  "define i32 @\"a prefix b\"() {\nentry:\n ret i32 42\n}\n"
  roundtrips?]]

(t:section "fence ordering with metadata")
[t:check
 "metadata does not hide acquire ordering"
 [with-module
  "fence"
  "define void @f() {\nentry:\n fence acquire, !annotation !0\n ret void\n}\n!0 = !{!\"test\"}\n"
  [lambda
   (m)
   [let
    [[ins
      [car
       [ir:block-instructions
        (car (ir:function-blocks (car (ir:module-functions m))))]]]]
    (= 4 (ir:instruction-ordering ins))]]]]

(t:section "instruction flag readers")
[t:check
 "quoted result name cannot forge flags; exact and fast-math survive"
 [with-module
  "flags"
  "define i32 @f(i32 %x, i32 %y) {\nentry:\n %\"x = add nsw\" = add nuw i32 %x, %y\n %r = sdiv exact i32 %x, %y\n ret i32 %r\n}\ndefine double @float(double %x, double %y) {\nentry:\n %r = fadd nnan ninf double %x, %y\n ret double %r\n}\n"
  [lambda
   (m)
   [let*
    [(fns (ir:module-functions m))
     (ints (ir:block-instructions (car (ir:function-blocks (car fns)))))
     (fp (car (ir:block-instructions (car (ir:function-blocks (cadr fns))))))]
    [and
     (ir:nuw-flag? (car ints))
     (not (ir:nsw-flag? (car ints)))
     (ir:exact-flag? (cadr ints))
     (= 6 (ir:fast-math-flags fp))]]]]]

(t:section "typed-pointer bitcode read by llvm-dis")
[when
 (config:capability? 'typed-pointers)
 [t:check
  "LLVM 16 disassembles element-typed pointer bitcode"
  [let
   ((ctx (ir:make-context)) (root "tests/tmp/llvm16-review"))
   [for-each
    (lambda (p) (unless (file-exists? p) (mkdir p)))
    (list "tests/tmp" root)]
   [dynamic-wind
    void
    [lambda
     ()
     (ir:context-use-typed-pointers! ctx)
     [let
      [[m
        [ir:parse-ir
         ctx
         "typed"
         "define float @f(float addrspace(1)* %p) {\nentry:\n %v = load float, float addrspace(1)* %p, align 4\n ret float %v\n}\n"]]]
      [dynamic-wind
       void
       [lambda
        ()
        (ir:verify-module m)
        [call-with-port
         [open-file-output-port
          (string-append root "/typed.bc")
          (file-options no-fail)]
         (lambda (p) (put-bytevector p (ir:module->bitcode m)))]]
       (lambda () (ir:module-dispose! m))]]
     [and
      [zero?
       [system
        [format
         "~a -opaque-pointers=0 tests/tmp/llvm16-review/typed.bc -o tests/tmp/llvm16-review/typed.ll"
         [shell-quote
          (string-append config:installation-directory "/bin/llvm-dis")]]]]
      [contains?
       (call-with-input-file (string-append root "/typed.ll") get-string-all)
       "float addrspace(1)* %p"]]]
    (lambda () (ir:context-dispose! ctx))]]]]

(t:summary-and-exit)
