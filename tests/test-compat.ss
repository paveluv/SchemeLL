;;; Cross-release contracts for the LLVM 16 adapters. All parsed fixtures pass
;;; LLVM's verifier before we inspect or unbuild them.
[import
 (chezscheme)
 (prefix (llvm ir) ir:)
 (prefix (llvm raw) LLVM)
 (prefix (llvm config) config:)
 (prefix (sll) sll:)
 (prefix (sll render) render:)
 (prefix (tests normalize) n:)
 (prefix (tests harness) t:)]

[let
 ()
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
  (with-module text action)
  [let*
   ((ctx (ir:make-context)) (m (ir:parse-ir ctx "compat" text)))
   [dynamic-wind
    void
    (lambda () (ir:verify-module m) (action m))
    (lambda () (ir:module-dispose! m) (ir:context-dispose! ctx))]]]
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
   (sll:unbuild m)
   #f]]
 [define
  (roundtrips? m)
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
       [lambda
        ()
        (ir:verify-module rebuilt)
        [string=?
         (n:comparable-ir (ir:module->string m))
         (n:comparable-ir (ir:module->string rebuilt))]]
       (lambda () (ir:module-dispose! rebuilt))]]]
    (lambda () (ir:context-dispose! ctx))]]]
 [define
  (instructions m)
  [apply
   append
   [map
    [lambda
     (f)
     (apply append (map ir:block-instructions (ir:function-blocks f)))]
    (ir:module-functions m)]]]

 (t:section "compatibility: operand bundle detection")
 [for-each
  [lambda
   (attributes)
   [t:check
    (string-append "bundle preserved or refused, call attributes: " attributes)
    [with-module
     [string-append
      "declare void @g()\ndefine void @f() {\nentry:\n call void @g() "
      attributes
      "[ \"deopt\"(i32 7), \"empty\"() ]\n ret void\n}\n"]
     [lambda
      (m)
      [if
       (config:capability? 'operand-bundles)
       (roundtrips? m)
       (refused? m "operand bundles")]]]]]
  '("" "nounwind ")]
 [t:check
  "quoted callee and array arguments cannot impersonate bundles"
  [with-module
   "declare void @\"g [ \\22fake\\22(\"([1 x i32])\ndefine void @f([1 x i32] %x) {\nentry:\n call void @\"g [ \\22fake\\22(\"([1 x i32] %x) nounwind\n ret void\n}\n"
   roundtrips?]]
 [t:check
  "invoke bundles with call-site attributes are preserved or refused"
  [with-module
   "declare void @g()\ndeclare i32 @personality(...)\ndefine void @f() personality ptr @personality {\nentry:\n invoke void @g() nounwind [ \"deopt\"(i32 7) ] to label %ok unwind label %eh\nok:\n ret void\neh:\n %e = landingpad {ptr, i32} cleanup\n resume {ptr, i32} %e\n}\n"
   [lambda
    (m)
    [if
     (config:capability? 'operand-bundles)
     (roundtrips? m)
     (refused? m "operand bundles")]]]]

 (t:section "compatibility: prefix and prologue detection")
 [for-each
  [lambda
   (entry)
   [t:check
    (car entry)
    (with-module (cadr entry) (lambda (m) (refused? m (caddr entry))))]]
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
  "quoted function, type and attribute names do not imply prefix data"
  [with-module
   "%\"{ prefix prologue\" = type {i32}\ndefine i32 @\"a prefix b\"(%\"{ prefix prologue\" %x) \"prefix\"=\" prologue \" {\nentry:\n ret i32 42\n}\n"
   roundtrips?]]
 [t:check
  "prologue's string content is not a prefix keyword"
  [with-module
   "define void @f() prologue [8 x i8] c\" prefix \" {\nentry:\n ret void\n}\n"
   [lambda
    (m)
    [let
     ((f (car (ir:module-functions m))))
     (and (not (ir:prefix-data? f)) (ir:prologue-data? f))]]]]

 (t:section "compatibility: fence ordering with metadata")
 [for-each
  [lambda
   (ordering)
   [t:check
    (format "fence ~a with named scope and metadata" (car ordering))
    [with-module
     [format
      "define void @f() {\nentry:\n fence syncscope(\"acquire \\22 seq_cst\") ~a, !annotation !0\n ret void\n}\n!0 = !{!\"test\"}\n"
      (car ordering)]
     [lambda
      (m)
      (= (cdr ordering) (ir:instruction-ordering (car (instructions m))))]]]]
  '[(acquire . 4)
    (release . 5)
    (acq_rel . 6)
    (seq_cst . 7)]]

 (t:section "compatibility: instruction flags and type predicates")
 [t:check
  "quoted result name cannot forge flags; exact and fast-math survive"
  [with-module
   "define i32 @f(i32 %x, i32 %y) {\nentry:\n %\"x = add nsw\" = add nuw i32 %x, %y\n %r = sdiv exact i32 %x, %y\n ret i32 %r\n}\ndefine double @float(double %x, double %y) {\nentry:\n %r = fadd nnan ninf double %x, %y\n ret double %r\n}\n"
   [lambda
    (m)
    [let
     ((ins (instructions m)))
     [and
      (ir:nuw-flag? (car ins))
      (not (ir:nsw-flag? (car ins)))
      (ir:exact-flag? (cadr ins))
      (= 6 (ir:fast-math-flags (list-ref ins 3)))]]]]]
 [t:check
  "fast-math applies only to eligible result types and operators"
  [with-module
   "declare void @g()\ndeclare [2 x double] @a()\ndefine double @f(i1 %c, double %x, double %y) {\nentry:\n %i = select i1 %c, i32 1, i32 2\n %f = select i1 %c, double %x, double %y\n call void @g()\n %a = call [2 x double] @a()\n ret double %f\n}\n"
   [lambda
    (m)
    [let
     ((ins (instructions m)))
     [and
      (not (ir:can-use-fast-math-flags? (car ins)))
      (ir:can-use-fast-math-flags? (cadr ins))
      (not (ir:can-use-fast-math-flags? (caddr ins)))
      (ir:can-use-fast-math-flags? (cadddr ins))
      (not (ir:can-use-fast-math-flags? (car (ir:module-functions m))))]]]]]

 (t:section "compatibility: wrap atomics and scalable splats")
 [t:check
  "wrap atomics can be inspected without unsupported C enum conversion"
  [with-module
   "define i32 @f(ptr %p, i32 %v) {\nentry:\n %a = atomicrmw volatile uinc_wrap ptr %p, i32 %v monotonic\n %b = atomicrmw udec_wrap ptr %p, i32 %v monotonic\n ret i32 %b\n}\n"
   [lambda
    (m)
    [let
     ((ins (instructions m)))
     [and
      (= 15 (ir:atomicrmw-binop (car ins)))
      (= 16 (ir:atomicrmw-binop (cadr ins)))]]]]]
 [t:check
  "the renderer preserves wrap atomics and instruction flags on LLVM 16"
  [with-module
   "define i32 @f(ptr %p, i32 %v) {\nentry:\n %a = atomicrmw uinc_wrap ptr %p, i32 %v monotonic\n %b = add nsw i32 %a, %v\n ret i32 %b\n}\n"
   [lambda
    (m)
    [with-module
     (render:sll->ll (sll:unbuild m))
     [lambda
      (r)
      [string=?
       (n:comparable-ir (ir:module->string m))
       (n:comparable-ir (ir:module->string r))]]]]]]
 [t:check
  "scalable splats render with syntax accepted by every qualified release"
  [with-module
   "define <vscale x 4 x i32> @f(<vscale x 4 x i32> %x) {\nentry:\n %r = add nuw <vscale x 4 x i32> %x, shufflevector (<vscale x 4 x i32> insertelement (<vscale x 4 x i32> poison, i32 3, i64 0), <vscale x 4 x i32> poison, <vscale x 4 x i32> zeroinitializer)\n ret <vscale x 4 x i32> %r\n}\n"
   [lambda
    (m)
    [with-module
     (render:sll->ll (sll:unbuild m))
     [lambda
      (r)
      [string=?
       (n:comparable-ir (ir:module->string m))
       (n:comparable-ir (ir:module->string r))]]]]]]

 (t:section "compatibility: large arrays and inrange GEPs")
 [t:check
  "array lengths retain all 64 bits when reading parsed IR"
  [with-module
   "@a = external global [5000000000 x i8]\n"
   [lambda
    (m)
    [and
     [=
      5000000000
      (ir:array-length (LLVMGlobalGetValueType (car (ir:module-globals m))))]
     [let
      ((ctx (ir:make-context)))
      [dynamic-wind
       void
       [lambda
        ()
        [let
         ((rendered (ir:parse-ir ctx "array" (render:sll->ll (sll:unbuild m)))))
         [dynamic-wind
          void
          [lambda
           ()
           [string=?
            (n:comparable-ir (ir:module->string m))
            (n:comparable-ir (ir:module->string rendered))]]
          (lambda () (ir:module-dispose! rendered))]]]
       (lambda () (ir:context-dispose! ctx))]]]]]]
 [t:check
  "large-array construction succeeds or refuses by capability"
  [let
   ((ctx (ir:make-context)))
   [dynamic-wind
    void
    [lambda
     ()
     [if
      (config:capability? 'array-length-64)
      [=
       5000000000
       (ir:array-length (ir:array-type (ir:int8-type ctx) 5000000000))]
      [guard
       [e
        [[and
          (who-condition? e)
          (eq? (condition-who e) 'llvm-config)
          (memq 'array-length-64 (condition-irritants e))]
         #t]]
       (ir:array-type (ir:int8-type ctx) 5000000000)
       #f]]]
    (lambda () (ir:context-dispose! ctx))]]]
 [t:check
  "both old and new inrange annotations are explicitly refused"
  [with-module
   [if
    (config:capability? 'gep-no-wrap-flags)
    "@a = external global [4 x i8]\n@p = global ptr getelementptr inbounds inrange(0, 4) ([4 x i8], ptr @a, i64 0, i64 1)\n"
    "@a = external global [4 x i8]\n@p = global ptr getelementptr inbounds ([4 x i8], ptr @a, i64 0, inrange i64 1)\n"]
   (lambda (m) (refused? m "inrange annotations"))]]
 [t:check
  "inrange in a quoted symbol is not an annotation"
  [with-module
   "@\" inrange( \" = external global [4 x i8]\n@p = global ptr getelementptr inbounds ([4 x i8], ptr @\" inrange( \", i64 0, i64 1)\n"
   roundtrips?]]
 [t:check
  "target extension types build everywhere, inspection is capability checked"
  [with-module
   "define void @f(target(\"spirv.Event\") %x) {\nentry:\n ret void\n}\n"
   [lambda
    (m)
    [if
     (config:capability? 'target-ext-types)
     (roundtrips? m)
     (refused? m "target extension type inspection")]]]]

 (t:section "compatibility: metadata value wrappers")
 [t:check
  "a null metadata operand is refused without a native crash"
  [with-module
   "declare void @llvm.review(metadata)\ndefine void @f() {\nentry:\n call void @llvm.review(metadata !0)\n ret void\n}\n!0 = !{null, !\"node\"}\n"
   [lambda
    (m)
    [and
     (not (ir:value-as-metadata? 0))
     (refused? m "metadata operand kind")]]]]
 [t:check
  "local and constant value wrappers differ from nodes and strings"
  [with-module
   "declare void @llvm.review(metadata, metadata, metadata, metadata)\ndefine void @f(i32 %x) {\nentry:\n call void @llvm.review(metadata i32 %x, metadata i32 7, metadata !0, metadata !\"text\")\n ret void\n}\n!0 = !{!\"node\"}\n"
   [lambda
    (m)
    [let
     ((call (car (instructions m))))
     [and
      (ir:value-as-metadata? (LLVMGetOperand call 0))
      (ir:value-as-metadata? (LLVMGetOperand call 1))
      (not (ir:value-as-metadata? (LLVMGetOperand call 2)))
      (not (ir:value-as-metadata? (LLVMGetOperand call 3)))
      (refused? m "value-as-metadata operands")]]]]]]
