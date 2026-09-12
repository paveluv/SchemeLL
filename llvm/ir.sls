;;; (llvm ir) -- layer 1: safe handles and IR construction.
;;;
;;; Ownership model (see project/RULES.md):
;;;   - Owning handles (context, module, builder) are records with a mutable
;;;     state field: owned | borrowed | consumed | disposed. All use goes
;;;     through *-live-ptr accessors that raise instead of segfaulting.
;;;   - Types, values and basic blocks are borrowed pointers (raw addresses);
;;;     they live exactly as long as their context.
[library
 (llvm ir)
 [export
  ;; contexts
  context?
  make-context
  wrap-context
  context-dispose!
  context-live-ptr
  ;; modules
  module?
  make-module
  module-dispose!
  module-live-ptr
  module-consume!
  module-context
  module->string
  verify-module
  set-module-target-triple!
  set-module-data-layout!
  run-module-passes!
  parse-ir
  take-diagnostics!
  ;; walking built IR (observation / disassembly)
  module-functions
  function-blocks
  block-instructions
  instruction-opcode
  icmp-predicate
  fcmp-predicate
  ;; builders
  builder?
  make-builder
  builder-dispose!
  builder-live-ptr
  ;; types
  void-type
  int-type
  int1-type
  int8-type
  int16-type
  int32-type
  int64-type
  float-type
  double-type
  half-type
  bfloat-type
  fp128-type
  x86fp80-type
  ppcfp128-type
  pointer-type
  function-type
  struct-type
  array-type
  vector-type
  scalable-vector-type
  named-type
  create-named-struct
  struct-set-body!
  value->string
  type-kind
  type-int-width
  type-return-type
  type-param-types
  type-vararg?
  struct-field-count
  type->string
  ;; functions / values
  add-function
  named-function
  function-type-of
  function-param
  function-params
  value-name
  set-value-name!
  declaration?
  set-alignment!
  ;; instruction flags
  set-nsw!
  set-nuw!
  set-exact!
  set-nneg!
  set-disjoint!
  set-volatile!
  set-fast-math-flags!
  fast-math-flags
  can-use-fast-math-flags?
  gep-no-wrap-flags
  nsw-flag?
  nuw-flag?
  exact-flag?
  nneg-flag?
  disjoint-flag?
  array-length
  prefix-data?
  prologue-data?
  value-as-metadata?
  ;; typed pointers (LLVM 16) and bitcode output
  context-use-typed-pointers!
  typed-pointer-type
  module->bitcode
  const-int
  const-real
  const-null
  undef-value
  poison-value
  const-vector
  block-address
  const-array
  const-struct
  const-named-struct
  const-string
  struct-name
  const-cast
  const-binop
  const-gep
  add-alias
  alias-aliasee
  alias-set-aliasee!
  module-aliases
  add-ifunc
  ifunc-resolver
  ifunc-set-resolver!
  module-ifuncs
  set-module-asm!
  metadata-type
  md-string
  md-node
  metadata-value
  value-as-metadata
  add-named-metadata!
  md-kind-id
  set-instruction-metadata!
  instruction-metadata
  value-address-space
  set-atomic-single-thread!
  set-externally-initialized!
  literal-struct-type?
  const-splat
  const-extractelement
  const-insertelement
  x86mmx-type
  x86amx-type
  target-ext-type
  set-gc!
  gc-name
  set-target!
  set-data-layout!
  create-operand-bundle
  dispose-operand-bundle!
  build-call-bundles
  build-invoke-bundles
  packed-struct-type?
  ;; module-level globals
  add-global
  set-initializer!
  set-global-constant!
  set-linkage!
  set-visibility!
  set-section!
  linkage
  module-globals
  ;; basic blocks / positioning
  append-block
  position-at-end!
  insert-block
  ;; instructions
  build-ret
  build-ret-void
  build-br
  build-cond-br
  build-switch
  add-case!
  build-indirect-br
  add-destination!
  build-unreachable
  build-freeze
  build-va-arg
  build-invoke
  build-resume
  build-landingpad
  add-clause!
  set-landingpad-cleanup!
  set-personality-fn!
  build-catchswitch
  add-handler!
  build-catchpad
  build-cleanuppad
  build-catchret
  build-cleanupret
  build-callbr
  inline-asm
  token-type
  build-extractelement
  build-insertelement
  build-shufflevector
  build-extractvalue
  build-insertvalue
  build-fence
  build-atomicrmw
  build-cmpxchg
  set-ordering!
  instruction-ordering
  set-weak!
  atomicrmw-binop
  cmpxchg-success-ordering
  cmpxchg-failure-ordering
  build-add
  build-sub
  build-mul
  build-sdiv
  build-udiv
  build-srem
  build-urem
  build-and
  build-or
  build-xor
  build-shl
  build-lshr
  build-ashr
  build-fadd
  build-fsub
  build-fmul
  build-fdiv
  build-frem
  build-neg
  build-fneg
  build-not
  build-icmp
  build-fcmp
  build-select
  build-phi
  phi-add-incoming!
  build-call
  build-alloca
  build-array-alloca
  build-load
  build-store
  build-gep
  build-gep/flags
  set-tail-call-kind!
  tail-call-kind
  set-function-call-conv!
  function-call-conv
  set-instruction-call-conv!
  instruction-call-conv
  enum-attribute-kind-named
  create-enum-attribute
  create-string-attribute
  add-function-attribute!
  add-callsite-attribute!
  function-attributes
  callsite-attributes
  attribute-enum?
  attribute-string?
  attribute-type?
  attribute-enum-kind
  attribute-enum-value
  attribute-string-kind
  attribute-string-value
  replace-all-uses!
  erase-instruction!
  delete-block!
  build-trunc
  build-zext
  build-sext
  build-si->fp
  build-ui->fp
  build-fp->si
  build-fp->ui
  build-fptrunc
  build-fpext
  build-ptr->int
  build-int->ptr
  build-bitcast
  build-addrspacecast]
 [import
  (chezscheme)
  (prefix (llvm raw) LLVM)
  (prefix (llvm base) base:)
  (prefix (llvm config) config:)
  (prefix (llvm text-flags) text:)]

 ;; ---- contexts -----------------------------------------------------------

 [define-record-type
  (context $make-context context?)
  (fields ptr (mutable state))
  (nongenerative llvm-context-v0)]

 ;; LLVM diagnostics (inline-asm errors etc.) are captured per process in (llvm
 ;; base); every context we create installs the recording handler, and
 ;; base:error attaches drained diagnostics to whatever it raises.
 ;; take-diagnostics! gives programmatic access.
 (define take-diagnostics! base:take-diagnostics!)

 [define
  (make-context)
  [let
   ((ptr (LLVMContextCreate)))
   (base:install-diagnostic-handler! ptr)
   ($make-context ptr 'owned)]]

 ;; Wrap a context pointer someone else owns (e.g. an ORC ThreadSafeContext).
 [define
  (wrap-context ptr)
  (base:install-diagnostic-handler! ptr)
  ($make-context ptr 'borrowed)]

 [define
  (context-live-ptr ctx)
  [let
   ((s (context-state ctx)))
   [unless
    (memq s '(owned borrowed))
    (base:error 'context "context is no longer live" s)]
   (context-ptr ctx)]]

 [define
  (context-dispose! ctx)
  [case
   (context-state ctx)
   [(owned)
    (LLVMContextDispose (context-ptr ctx))
    (context-state-set! ctx 'disposed)]
   ((borrowed) (context-state-set! ctx 'disposed)) ; owner frees the C object
   (else (void))]]

 ;; ---- modules ------------------------------------------------------------

 ;; record-type name is llvm-module because `module` is a Chez keyword
 [define-record-type
  (llvm-module $make-module module?)
  [fields
   (immutable ptr module-ptr)
   (immutable context module-context)
   (mutable state module-state module-state-set!)]
  (nongenerative llvm-module-v0)]

 [define
  (make-module ctx name)
  [$make-module
   (LLVMModuleCreateWithNameInContext name (context-live-ptr ctx))
   ctx
   'owned]]

 [define
  (module-live-ptr m)
  [unless
   (eq? (module-state m) 'owned)
   [base:error
    'module
    "module is no longer live (handed to JIT or disposed?)"
    (module-state m)]]
  (module-ptr m)]

 ;; Called by (llvm jit) when ownership moves into a ThreadSafeModule.
 [define
  (module-consume! m)
  (module-live-ptr m)
  (module-state-set! m 'consumed)]

 [define
  (module-dispose! m)
  [when
   (eq? (module-state m) 'owned)
   (LLVMDisposeModule (module-ptr m))
   (module-state-set! m 'disposed)]]

 [define
  (module->string m)
  (base:cstring->string/dispose (LLVMPrintModuleToString (module-live-ptr m)))]

 ;; Raises with LLVM's diagnostic if the module is invalid.
 [define
  (verify-module m)
  [let-values
   [[(failed msg-ptr)
     [base:call-with-out-ptr
      [lambda
       (out)
       (LLVMVerifyModule (module-live-ptr m) 2 out)]]]] ; 2 = return-status
   [let
    ((msg (base:cstring->string/dispose msg-ptr)))
    (base:check-bool 'ir:verify-module failed msg)]]]

 [define
  (set-module-target-triple! m triple)
  (LLVMSetTarget (module-live-ptr m) triple)]

 [define
  (set-module-data-layout! m layout-string)
  (LLVMSetDataLayout (module-live-ptr m) layout-string)]

 ;; Run new-pass-manager passes, e.g. (run-module-passes! m "default<O2>").
 [define
  (run-module-passes! m passes)
  [let
   ((opts (LLVMCreatePassBuilderOptions)))
   [let
    ((err (LLVMRunPasses (module-live-ptr m) passes base:null-ptr opts)))
    (LLVMDisposePassBuilderOptions opts)
    (base:check-error-ref 'ir:run-module-passes! err)]]]

 ;; Parse textual LLVM IR into a fresh module, using LLVM's own parser. Raises
 ;; with the parser's diagnostics on malformed IR.
 [define
  (parse-ir ctx name text)
  [let*
   [(bv (string->utf8 text))
    (len (bytevector-length bv))
    (buf (foreign-alloc (fxmax 1 len)))]
   [do
    ((i 0 (fx+ i 1)))
    ((fx= i len))
    (foreign-set! 'unsigned-8 buf i (bytevector-u8-ref bv i))]
   [let
    ((membuf (LLVMCreateMemoryBufferWithMemoryRangeCopy buf len name)))
    (foreign-free buf)
    [let
     ((mod-out (foreign-alloc 8)))
     (foreign-set! 'unsigned-64 mod-out 0 0)
     ;; ParseIRInContext consumes membuf, success or not
     [let-values
      [[(failed msg-ptr)
        [base:call-with-out-ptr
         [lambda
          (err-out)
          [LLVMParseIRInContext
           (context-live-ptr ctx)
           membuf
           mod-out
           err-out]]]]]
      [let
       ((mp (foreign-ref 'unsigned-64 mod-out 0)))
       (foreign-free mod-out)
       [base:check-bool
        'ir:parse-ir
        failed
        (base:cstring->string/dispose msg-ptr)]
       ($make-module mp ctx 'owned)]]]]]]

 ;; ---- walking built IR ------------------------------------------------------

 [define
  (ptr-chain first next start)
  [let
   loop
   ((p (first start)) (acc '()))
   (if (base:null-ptr? p) (reverse acc) (loop (next p) (cons p acc)))]]

 [define
  (module-functions m)
  (ptr-chain LLVMGetFirstFunction LLVMGetNextFunction (module-live-ptr m))]
 [define
  (function-blocks f)
  (ptr-chain LLVMGetFirstBasicBlock LLVMGetNextBasicBlock f)]
 [define
  (block-instructions bb)
  (ptr-chain LLVMGetFirstInstruction LLVMGetNextInstruction bb)]

 ;; raw LLVMOpcode / predicate enum values; interpretation is the caller's
 (define (instruction-opcode ins) (LLVMGetInstructionOpcode ins))
 (define (icmp-predicate ins) (LLVMGetICmpPredicate ins))
 (define (fcmp-predicate ins) (LLVMGetFCmpPredicate ins))

 ;; ---- builders -----------------------------------------------------------

 [define-record-type
  (builder $make-builder builder?)
  (fields ptr (mutable state))
  (nongenerative llvm-builder-v0)]

 [define
  (make-builder ctx)
  ($make-builder (LLVMCreateBuilderInContext (context-live-ptr ctx)) 'owned)]

 [define
  (builder-live-ptr b)
  [unless
   (eq? (builder-state b) 'owned)
   (base:error 'builder "builder is no longer live" (builder-state b))]
  (builder-ptr b)]

 [define
  (builder-dispose! b)
  [when
   (eq? (builder-state b) 'owned)
   (LLVMDisposeBuilder (builder-ptr b))
   (builder-state-set! b 'disposed)]]

 ;; ---- types ---------------------------------------------------------------

 (define (void-type ctx) (LLVMVoidTypeInContext (context-live-ptr ctx)))
 (define (int1-type ctx) (LLVMInt1TypeInContext (context-live-ptr ctx)))
 (define (int8-type ctx) (LLVMInt8TypeInContext (context-live-ptr ctx)))
 (define (int16-type ctx) (LLVMInt16TypeInContext (context-live-ptr ctx)))
 (define (int32-type ctx) (LLVMInt32TypeInContext (context-live-ptr ctx)))
 (define (int64-type ctx) (LLVMInt64TypeInContext (context-live-ptr ctx)))
 (define (int-type ctx bits) (LLVMIntTypeInContext (context-live-ptr ctx) bits))
 (define (float-type ctx) (LLVMFloatTypeInContext (context-live-ptr ctx)))
 (define (double-type ctx) (LLVMDoubleTypeInContext (context-live-ptr ctx)))
 (define (half-type ctx) (LLVMHalfTypeInContext (context-live-ptr ctx)))
 (define (bfloat-type ctx) (LLVMBFloatTypeInContext (context-live-ptr ctx)))
 (define (fp128-type ctx) (LLVMFP128TypeInContext (context-live-ptr ctx)))
 (define (x86fp80-type ctx) (LLVMX86FP80TypeInContext (context-live-ptr ctx)))
 (define (ppcfp128-type ctx) (LLVMPPCFP128TypeInContext (context-live-ptr ctx)))

 [define
  pointer-type
  [case-lambda
   ((ctx) (pointer-type ctx 0))
   [(ctx address-space)
    (LLVMPointerTypeInContext (context-live-ptr ctx) address-space)]]]

 [define
  function-type
  [case-lambda
   ((ret params) (function-type ret params #f))
   [(ret params vararg?)
    [base:call-with-pointer-array
     params
     (lambda (arr n) (LLVMFunctionType ret arr n (if vararg? 1 0)))]]]]

 [define
  struct-type
  [case-lambda
   ((ctx elems) (struct-type ctx elems #f))
   [(ctx elems packed?)
    [base:call-with-pointer-array
     elems
     [lambda
      (arr n)
      [LLVMStructTypeInContext
       (context-live-ptr ctx)
       arr
       n
       (if packed? 1 0)]]]]]]

 ;; 64-bit array lengths are LLVM 17; before that the C API takes unsigned
 [define
  (array-type elem-type count)
  [if
   (config:capability? 'array-length-64)
   (LLVMArrayType2 elem-type count)
   (LLVMArrayType elem-type count)]]
 [define
  (array-length ty)
  [if
   (config:capability? 'array-length-64)
   (LLVMGetArrayLength2 ty)
   (LLVMGetArrayLength ty)]]

 (define (vector-type elem-type count) (LLVMVectorType elem-type count))

 [define
  (scalable-vector-type elem-type count)
  (LLVMScalableVectorType elem-type count)]

 ;; named (identified) struct types, registered in the context by name
 [define
  (named-type ctx name)
  [let
   ((ty (LLVMGetTypeByName2 (context-live-ptr ctx) name)))
   (and (not (base:null-ptr? ty)) ty)]]
 [define
  (create-named-struct ctx name)
  (LLVMStructCreateNamed (context-live-ptr ctx) name)]
 [define
  (struct-set-body! ty elems packed?)
  [base:call-with-pointer-array
   elems
   (lambda (arr n) (LLVMStructSetBody ty arr n (if packed? 1 0)))]]

 ;; LLVM 19/20 preserve these numeric values; 20 leaves the old MMX slot empty.
 [define
  type-kinds
  '#(void
     half
     float
     double
     x86-fp80
     fp128
     ppc-fp128
     label
     integer
     function
     struct
     array
     pointer
     vector
     metadata
     x86-mmx
     token
     scalable-vector
     bfloat
     x86-amx
     target-ext)]

 [define
  (type-kind t)
  [let
   ((k (LLVMGetTypeKind t)))
   (if (fx< -1 k (vector-length type-kinds)) (vector-ref type-kinds k) k)]]

 (define (type-int-width t) (LLVMGetIntTypeWidth t))
 (define (type-return-type ft) (LLVMGetReturnType ft))
 (define (type-vararg? ft) (not (zero? (LLVMIsFunctionVarArg ft))))

 (define (struct-field-count ty) (LLVMCountStructElementTypes ty))

 [define
  (type-param-types ft)
  [let*
   ((n (LLVMCountParamTypes ft)) (arr (foreign-alloc (fxmax 8 (fx* 8 n)))))
   (LLVMGetParamTypes ft arr)
   [let
    loop
    ((i (fx- n 1)) (acc '()))
    [if
     (fx< i 0)
     (begin (foreign-free arr) acc)
     (loop (fx- i 1) (cons (foreign-ref 'unsigned-64 arr (fx* 8 i)) acc))]]]]

 [define
  (type->string t)
  (base:cstring->string/dispose (LLVMPrintTypeToString t))]

 ;; ---- functions / values ----------------------------------------------------

 [define
  (add-function m name ftype)
  (LLVMAddFunction (module-live-ptr m) name ftype)]

 [define
  (named-function m name)
  [let
   ((f (LLVMGetNamedFunction (module-live-ptr m) name)))
   (and (not (base:null-ptr? f)) f)]]

 ;; With opaque pointers, LLVMTypeOf on a function gives `ptr`; this gives the
 ;; actual function type.
 (define (function-type-of f) (LLVMGlobalGetValueType f))

 (define (function-param f i) (LLVMGetParam f i))

 [define
  (function-params f)
  [let
   ((n (LLVMCountParams f)))
   [let
    loop
    ((i (fx- n 1)) (acc '()))
    (if (fx< i 0) acc (loop (fx- i 1) (cons (LLVMGetParam f i) acc)))]]]

 [define
  (value-name v)
  [let-values
   [[(str-ptr len)
     (base:call-with-out-ptr (lambda (out) (LLVMGetValueName2 v out)))]]
   (base:cstring->string/len str-ptr len)]]

 [define
  (set-value-name! v name)
  (LLVMSetValueName2 v name (bytevector-length (string->utf8 name)))]

 (define (set-alignment! v bytes) (LLVMSetAlignment v bytes))

 ;; instruction flags: setters set the flag; getters return bitmasks/booleans.
 ;; The setters are LLVM 18 C API (the raw bindings refuse them before that);
 ;; the getters fall back to reading LLVM's own printer through (llvm
 ;; text-flags) on releases without accessors.
 (define (set-nsw! v) (LLVMSetNSW v 1))
 (define (set-nuw! v) (LLVMSetNUW v 1))
 (define (set-exact! v) (LLVMSetExact v 1))
 (define (set-nneg! v) (LLVMSetNNeg v 1))
 (define (set-disjoint! v) (LLVMSetIsDisjoint v 1))
 (define (set-volatile! v) (LLVMSetVolatile v 1))
 (define (set-fast-math-flags! v mask) (LLVMSetFastMathFlags v mask))
 (define flag-accessors? (config:capability? 'flag-accessors))
 [define
  (flag-getter c-get flag)
  [lambda
   (v)
   (if flag-accessors? (not (zero? (c-get v))) (text:leading-flag? v flag))]]
 (define nsw-flag? (flag-getter (lambda (v) (LLVMGetNSW v)) 'nsw))
 (define nuw-flag? (flag-getter (lambda (v) (LLVMGetNUW v)) 'nuw))
 (define exact-flag? (flag-getter (lambda (v) (LLVMGetExact v)) 'exact))
 (define nneg-flag? (flag-getter (lambda (v) (LLVMGetNNeg v)) 'nneg))
 [define
  disjoint-flag?
  (flag-getter (lambda (v) (LLVMGetIsDisjoint v)) 'disjoint)]
 ;; LLVMFastMathFlags bits, as printed
 [define
  fast-math-words
  '[(reassoc  . 1  )
    (nnan     . 2  )
    (ninf     . 4  )
    (nsz      . 8  )
    (arcp     . 16 )
    (contract . 32 )
    (afn      . 64 )
    (fast     . 127)]]
 [define
  (fast-math-flags v)
  [if
   flag-accessors?
   (LLVMGetFastMathFlags v)
   [fold-left
    [lambda
     (mask flag)
     [let
      ((e (assq flag fast-math-words)))
      (if e (bitwise-ior mask (cdr e)) mask)]]
    0
    (text:leading-flags v)]]]
 ;; the FPMathOperators, for releases without LLVMCanValueUseFastMathFlags
 (define fp-math-opcodes '(fneg fadd fsub fmul fdiv frem fcmp select phi call))
 [define
  (can-use-fast-math-flags? v)
  [if
   flag-accessors?
   (not (zero? (LLVMCanValueUseFastMathFlags v)))
   [let-values
    (((op flags) (text:instruction-head v)))
    (and (memq op fp-math-opcodes) #t)]]]
 ;; LLVMGEPNoWrapFlags: inbounds 1 (implies nusw 2), nuw 4. Before LLVM 19 only
 ;; inbounds exists, read through LLVMIsInBounds.
 [define
  (gep-no-wrap-flags v)
  [if
   (config:capability? 'gep-no-wrap-flags)
   (LLVMGEPGetNoWrapFlags v)
   (if (zero? (LLVMIsInBounds v)) 0 3)]]

 (define (declaration? f) (not (zero? (LLVMIsDeclaration f))))

 ;; prefix/prologue data: LLVM 18 accessors; before that, the printed function
 ;; header carries the keywords
 [define
  (function-header-has? f word)
  [let*
   [(text (base:cstring->string/dispose (LLVMPrintValueToString f)))
    (n (string-length text))
    [end
     [let
      loop
      ((i 0))
      [cond
       ((= i n) n)
       ((memv (string-ref text i) '(#\{ #\newline)) i)
       (else (loop (+ i 1)))]]]
    (header (substring text 0 end))
    (m (string-length word))]
   [let
    loop
    ((i 0))
    [and
     (<= (+ i m) (string-length header))
     (or (string=? word (substring header i (+ i m))) (loop (+ i 1)))]]]]
 [define
  (prefix-data? f)
  [if
   (config:capability? 'prefix-data-inspection)
   (not (zero? (LLVMHasPrefixData f)))
   (function-header-has? f " prefix ")]]
 [define
  (prologue-data? f)
  [if
   (config:capability? 'prefix-data-inspection)
   (not (zero? (LLVMHasPrologueData f)))
   (function-header-has? f " prologue ")]]

 ;; a metadata-typed value that wraps an SSA value (LLVMIsAValueAsMetadata is
 ;; LLVM 17; before that: metadata-typed, neither string nor node)
 [define
  (value-as-metadata? v)
  [if
   (config:capability? 'value-as-metadata-inspection)
   (not (zero? (LLVMIsAValueAsMetadata v)))
   [and
    (eq? (type-kind (LLVMTypeOf v)) 'metadata)
    (zero? (LLVMIsAMDString v))
    (zero? (LLVMIsAMDNode v))]]]

 ;; ---- typed pointers (LLVM 16) and bitcode ----------------------------------

 ;; Switch a fresh context to typed pointers, before any type is created in it.
 ;; Only LLVM 16 can (the capability is refused elsewhere); IR parsed or built
 ;; in the context then carries element types, and its bitcode is readable by
 ;; consumers that predate opaque pointers.
 [define
  (context-use-typed-pointers! ctx)
  (config:require-capability! 'typed-pointers)
  (LLVMContextSetOpaquePointers (context-live-ptr ctx) 0)]

 ;; a pointer type to elem-type in an address space; the element type is ignored
 ;; by opaque-pointer contexts
 [define
  typed-pointer-type
  [case-lambda
   ((elem-type) (typed-pointer-type elem-type 0))
   ((elem-type addrspace) (LLVMPointerType elem-type addrspace))]]

 ;; the module's bitcode, as a fresh bytevector
 [define
  (module->bitcode m)
  [let
   ((mb (LLVMWriteBitcodeToMemoryBuffer (module-live-ptr m))))
   [dynamic-wind
    void
    [lambda
     ()
     [let*
      [(start (LLVMGetBufferStart mb))
       (n (LLVMGetBufferSize mb))
       (bv (make-bytevector n))]
      [do
       ((i 0 (fx+ i 1)))
       ((fx= i n) bv)
       (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 start i))]]]
    (lambda () (LLVMDisposeMemoryBuffer mb))]]]

 [define
  (const-int ty n)
  [if
   (and (>= n (- (expt 2 63))) (< n (expt 2 64)))
   (LLVMConstInt ty (bitwise-and n #xFFFFFFFFFFFFFFFF) (if (< n 0) 1 0))
   ;; wider than the C API's uint64: go through decimal text
   [let
    ((s (number->string n)))
    (LLVMConstIntOfStringAndSize ty s (string-length s) 10)]]]

 (define (const-real ty x) (LLVMConstReal ty (inexact x)))
 (define (const-null ty) (LLVMConstNull ty))
 (define (undef-value ty) (LLVMGetUndef ty))
 (define (poison-value ty) (LLVMGetPoison ty))

 ;; scalars: a list of constant values, all of the same type
 [define
  (const-vector scalars)
  [base:call-with-pointer-array
   scalars
   (lambda (arr n) (LLVMConstVector arr n))]]

 ;; the address of a (non-entry) basic block, as a ptr constant
 (define (block-address fn block) (LLVMBlockAddress fn block))

 [define
  (const-array elem-type constants)
  [base:call-with-pointer-array
   constants
   [lambda
    (arr n)
    [if
     (config:capability? 'array-length-64)
     (LLVMConstArray2 elem-type arr n)
     (LLVMConstArray elem-type arr n)]]]]

 ;; the name of an identified struct type, #f for literal structs
 [define
  (struct-name ty)
  [let
   ((s (base:cstring->string (LLVMGetStructName ty))))
   (and s (not (string=? s "")) s)]]

 ;; ---- gc / module target strings ----------------------------------------

 (define (set-gc! f name) (LLVMSetGCString f name))
 (define (literal-struct-type? ty) (not (zero? (LLVMIsLiteralStruct ty))))

 (define (const-extractelement v i) (LLVMConstExtractElement v i))
 (define (const-insertelement v e i) (LLVMConstInsertElement v e i))

 ;; splat constant for a (possibly scalable) vector type: the
 ;; insertelement+shufflevector constexpr chain LLVM 19 spells `splat (ty
 ;; elem)`; folds to a plain vector for fixed types
 [define
  (const-splat vty elem)
  [let*
   [(cx (LLVMGetTypeContext vty))
    (i32 (LLVMIntTypeInContext cx 32))
    (i64 (LLVMIntTypeInContext cx 64))
    (n (LLVMGetVectorSize vty))
    (scalable? (eq? (type-kind vty) 'scalable-vector))
    [mask-ty
     (if scalable? (LLVMScalableVectorType i32 n) (LLVMVectorType i32 n))]
    (poison (LLVMGetPoison vty))]
   [LLVMConstShuffleVector
    (LLVMConstInsertElement poison elem (LLVMConstInt i64 0 0))
    poison
    (LLVMConstNull mask-ty)]]]
 [define
  (value-address-space v)       ; of a pointer-typed value
  (LLVMGetPointerAddressSpace (LLVMTypeOf v))]
 (define (set-atomic-single-thread! v) (LLVMSetAtomicSingleThread v 1))
 (define (set-externally-initialized! g) (LLVMSetExternallyInitialized g 1))
 (define (gc-name f) (base:cstring->string (LLVMGetGC f)))
 (define (set-target! m s) (LLVMSetTarget (module-live-ptr m) s))
 (define (set-data-layout! m s) (LLVMSetDataLayout (module-live-ptr m) s))

 ;; ---- operand bundles ------------------------------------------------------
 ;; created, passed to a bundle-aware builder (which copies them into the
 ;; instruction), then disposed by the caller

 [define
  (create-operand-bundle tag args)
  [base:call-with-pointer-array
   args
   [lambda
    (arr n)
    [LLVMCreateOperandBundle
     tag
     (bytevector-length (string->utf8 tag))
     arr
     n]]]]
 (define (dispose-operand-bundle! b) (LLVMDisposeOperandBundle b))

 [define
  (build-call-bundles b fn-type fn args bundles name)
  [base:call-with-pointer-array
   args
   [lambda
    (aarr an)
    [base:call-with-pointer-array
     bundles
     [lambda
      (barr bn)
      [LLVMBuildCallWithOperandBundles
       (builder-live-ptr b)
       fn-type
       fn
       aarr
       an
       barr
       bn
       name]]]]]]
 [define
  (build-invoke-bundles b fn-type fn args then-block unwind-block bundles name)
  [base:call-with-pointer-array
   args
   [lambda
    (aarr an)
    [base:call-with-pointer-array
     bundles
     [lambda
      (barr bn)
      [LLVMBuildInvokeWithOperandBundles
       (builder-live-ptr b)
       fn-type
       fn
       aarr
       an
       then-block
       unwind-block
       barr
       bn
       name]]]]]]

 ;; ---- metadata operands --------------------------------------------------
 ;; MetadataRef makers plus the Value wrapper for operand positions

 (define (metadata-type ctx) (LLVMMetadataTypeInContext (context-live-ptr ctx)))
 (define (x86mmx-type ctx) (LLVMX86MMXTypeInContext (context-live-ptr ctx)))
 (define (x86amx-type ctx) (LLVMX86AMXTypeInContext (context-live-ptr ctx)))
 [define
  (target-ext-type ctx name type-params int-params)
  [base:call-with-pointer-array
   type-params
   [lambda
    (tarr tn)
    [let
     ((iarr (foreign-alloc (fxmax 4 (fx* 4 (length int-params))))))
     [do
      ((ps int-params (cdr ps)) (i 0 (fx+ i 1)))
      ((null? ps))
      (foreign-set! 'unsigned-32 iarr (fx* 4 i) (car ps))]
     [let
      [[ty
        [LLVMTargetExtTypeInContext
         (context-live-ptr ctx)
         name
         tarr
         tn
         iarr
         (length int-params)]]]
      (foreign-free iarr)
      ty]]]]]
 [define
  (md-string ctx s)             ; -> MetadataRef; the length is in BYTES
  [LLVMMDStringInContext2
   (context-live-ptr ctx)
   s
   (bytevector-length (string->utf8 s))]]
 ;; instruction-attached metadata (!kind): presence is the point; the node
 ;; content is an empty tuple
 [define
  (md-kind-id ctx name)
  (LLVMGetMDKindIDInContext (context-live-ptr ctx) name (string-length name))]
 [define
  (set-instruction-metadata! ctx instr kind-name)
  [LLVMSetMetadata
   instr
   (md-kind-id ctx kind-name)
   (metadata-value ctx (md-node ctx '()))]]
 [define
  (instruction-metadata ctx instr kind-name)
  [let
   ((v (LLVMGetMetadata instr (md-kind-id ctx kind-name))))
   (and (not (base:null-ptr? v)) v)]]

 [define
  (md-node ctx mds)             ; MetadataRefs -> MetadataRef
  [base:call-with-pointer-array
   mds
   (lambda (arr n) (LLVMMDNodeInContext2 (context-live-ptr ctx) arr n))]]
 [define
  (metadata-value ctx md)       ; MetadataRef -> ValueRef
  (LLVMMetadataAsValue2 (context-live-ptr ctx) md)]
 ;; a value (function, constant, ...) as a metadata operand
 (define (value-as-metadata v) (LLVMValueAsMetadata v))
 ;; append an MDNode to a module's named metadata (!name = !{...}); module flags
 ;; are the named metadata "llvm.module.flags", whose nodes are !{i32 behavior,
 ;; !"key", value}
 [define
  (add-named-metadata! m name node)
  [LLVMAddNamedMetadataOperand
   (module-live-ptr m)
   name
   (metadata-value (module-context m) node)]]

 ;; ---- global aliases ---------------------------------------------------

 [define
  add-alias
  [case-lambda
   ((m value-ty aliasee name) (add-alias m value-ty aliasee name 0))
   [(m value-ty aliasee name addrspace)
    (LLVMAddAlias2 (module-live-ptr m) value-ty addrspace aliasee name)]]]
 (define (alias-aliasee a) (LLVMAliasGetAliasee a))
 (define (alias-set-aliasee! a v) (LLVMAliasSetAliasee a v))
 [define
  (module-aliases m)
  [ptr-chain
   LLVMGetFirstGlobalAlias
   LLVMGetNextGlobalAlias
   (module-live-ptr m)]]
 [define
  (add-ifunc m name fnty resolver)
  [LLVMAddGlobalIFunc
   (module-live-ptr m)
   name
   (bytevector-length (string->utf8 name))
   fnty
   0
   resolver]]
 (define (ifunc-resolver i) (LLVMGetGlobalIFuncResolver i))
 (define (ifunc-set-resolver! i r) (LLVMSetGlobalIFuncResolver i r))
 [define
  (module-ifuncs m)
  [ptr-chain
   LLVMGetFirstGlobalIFunc
   LLVMGetNextGlobalIFunc
   (module-live-ptr m)]]
 [define
  (set-module-asm! m s)
  [LLVMSetModuleInlineAsm2
   (module-live-ptr m)
   s
   (bytevector-length (string->utf8 s))]]

 ;; ---- constant expressions -------------------------------------------
 ;; constructed via ConstantExpr::get, which folds symmetrically with the parser
 ;; (unlike the IRBuilder's instruction folding)

 [define
  (const-cast op v ty)
  [[case
    op
    ((trunc) LLVMConstTrunc)
    ((ptrtoint) LLVMConstPtrToInt)
    ((inttoptr) LLVMConstIntToPtr)
    ((bitcast) LLVMConstBitCast)
    ((addrspacecast) LLVMConstAddrSpaceCast)
    (else (base:error 'const-cast "not a constexpr cast opcode" op))]
   v
   ty]]

 ;; the C API has no combined nuw+nsw constructors
 [define
  (const-binop op nuw? nsw? a b)
  [[case
    op
    [(add)
     (cond (nsw? LLVMConstNSWAdd) (nuw? LLVMConstNUWAdd) (else LLVMConstAdd))]
    [(sub)
     (cond (nsw? LLVMConstNSWSub) (nuw? LLVMConstNUWSub) (else LLVMConstSub))]
    [(mul)
     (cond (nsw? LLVMConstNSWMul) (nuw? LLVMConstNUWMul) (else LLVMConstMul))]
    ((xor) LLVMConstXor)
    (else (base:error 'const-binop "not a constexpr binop opcode" op))]
   a
   b]]

 ;; GEP no-wrap masks before LLVM 19: only plain (0) and inbounds (1, which
 ;; implies nusw 2) have builders; nusw alone and nuw need the flag API
 [define
  (gep-flags-buildable? flags)
  (or (config:capability? 'gep-no-wrap-flags) (memv flags '(0 1 3)))]
 [define
  (require-gep-flags! flags)
  [unless
   (gep-flags-buildable? flags)
   (config:require-capability! 'gep-no-wrap-flags)]]
 [define
  (const-gep src-elem-ty ptr indices flags)
  (require-gep-flags! flags)
  [base:call-with-pointer-array
   indices
   [lambda
    (arr n)
    [cond
     [(config:capability? 'gep-no-wrap-flags)
      (LLVMConstGEPWithNoWrapFlags src-elem-ty ptr arr n flags)]
     ((zero? flags) (LLVMConstGEP2 src-elem-ty ptr arr n))
     (else (LLVMConstInBoundsGEP2 src-elem-ty ptr arr n))]]]]

 [define
  (const-named-struct ty constants)
  [base:call-with-pointer-array
   constants
   (lambda (arr n) (LLVMConstNamedStruct ty arr n))]]

 [define
  const-struct                  ; literal (anonymous) struct constant
  [case-lambda
   ((ctx constants) (const-struct ctx constants #f))
   [(ctx constants packed?)
    [base:call-with-pointer-array
     constants
     [lambda
      (arr n)
      [LLVMConstStructInContext
       (context-live-ptr ctx)
       arr
       n
       (if packed? 1 0)]]]]]]

 (define (packed-struct-type? ty) (not (zero? (LLVMIsPackedStruct ty))))

 ;; bytes of s -- a string's utf8, or a bytevector as is -- as an i8 array
 ;; constant; null-terminate? adds the final \00
 [define
  (const-string ctx s null-terminate?)
  [let
   [(sized? (config:capability? 'sized-string-constants))
    (dont-terminate (if null-terminate? 0 1))]
   [if
    (bytevector? s)
    [(if sized? LLVMConstStringInContext2/bytes LLVMConstStringInContext/bytes)
     (context-live-ptr ctx)
     s
     (bytevector-length s)
     dont-terminate]
    [(if sized? LLVMConstStringInContext2 LLVMConstStringInContext)
     (context-live-ptr ctx)
     s
     (bytevector-length (string->utf8 s))
     dont-terminate]]]]

 ;; ---- module-level globals -------------------------------------------------

 [define
  add-global
  [case-lambda
   ((m ty name) (LLVMAddGlobal (module-live-ptr m) ty name))
   [(m ty name addrspace)
    (LLVMAddGlobalInAddressSpace (module-live-ptr m) ty name addrspace)]]]

 ;; a value's textual form, e.g. "i128 -5" (used for wide constants)
 [define
  (value->string v)
  (base:cstring->string/dispose (LLVMPrintValueToString v))]

 (define (set-initializer! g const) (LLVMSetInitializer g const))
 (define (set-global-constant! g) (LLVMSetGlobalConstant g 1))
 (define (set-linkage! g linkage-int) (LLVMSetLinkage g linkage-int))
 ;; 0 default, 1 hidden, 2 protected
 (define (set-visibility! g vis-int) (LLVMSetVisibility g vis-int))
 (define (set-section! g name) (LLVMSetSection g name))
 (define (linkage g) (LLVMGetLinkage g))

 [define
  (module-globals m)
  (ptr-chain LLVMGetFirstGlobal LLVMGetNextGlobal (module-live-ptr m))]

 ;; ---- basic blocks
 ;; ------------------------------------------------------------

 [define
  (append-block ctx fn name)
  (LLVMAppendBasicBlockInContext (context-live-ptr ctx) fn name)]

 [define
  (position-at-end! b block)
  (LLVMPositionBuilderAtEnd (builder-live-ptr b) block)]

 (define (insert-block b) (LLVMGetInsertBlock (builder-live-ptr b)))

 ;; ---- instructions
 ;; --------------------------------------------------------------

 (define (build-ret b v) (LLVMBuildRet (builder-live-ptr b) v))
 (define (build-ret-void b) (LLVMBuildRetVoid (builder-live-ptr b)))
 (define (build-br b block) (LLVMBuildBr (builder-live-ptr b) block))
 [define
  (build-cond-br b cond then-block else-block)
  (LLVMBuildCondBr (builder-live-ptr b) cond then-block else-block)]

 [define
  (build-switch b v else-block ncases)
  (LLVMBuildSwitch (builder-live-ptr b) v else-block ncases)]
 [define
  (add-case! switch on-const dest-block)
  (LLVMAddCase switch on-const dest-block)]
 [define
  (build-indirect-br b addr ndests)
  (LLVMBuildIndirectBr (builder-live-ptr b) addr ndests)]
 (define (add-destination! ibr dest-block) (LLVMAddDestination ibr dest-block))
 (define (build-unreachable b) (LLVMBuildUnreachable (builder-live-ptr b)))

 ;; ---- exception handling ---------------------------------------------------

 [define
  (build-invoke b fn-type fn args then-block unwind-block name)
  [base:call-with-pointer-array
   args
   [lambda
    (arr n)
    [LLVMBuildInvoke2
     (builder-live-ptr b)
     fn-type
     fn
     arr
     n
     then-block
     unwind-block
     name]]]]

 (define (build-resume b exn) (LLVMBuildResume (builder-live-ptr b) exn))

 [define
  (build-landingpad b ty nclauses name)
  (LLVMBuildLandingPad (builder-live-ptr b) ty base:null-ptr nclauses name)]

 (define (add-clause! lp clause-const) (LLVMAddClause lp clause-const))
 (define (set-landingpad-cleanup! lp) (LLVMSetCleanup lp 1))
 (define (set-personality-fn! f pers) (LLVMSetPersonalityFn f pers))

 ;; unwind-block: #f = `unwind to caller`
 [define
  (build-catchswitch b parent-pad unwind-block nhandlers name)
  [LLVMBuildCatchSwitch
   (builder-live-ptr b)
   parent-pad
   (or unwind-block base:null-ptr)
   nhandlers
   name]]
 (define (add-handler! cs dest-block) (LLVMAddHandler cs dest-block))

 [define
  (build-catchpad b parent-pad args name)
  [base:call-with-pointer-array
   args
   [lambda
    (arr n)
    (LLVMBuildCatchPad (builder-live-ptr b) parent-pad arr n name)]]]
 [define
  (build-cleanuppad b parent-pad args name)
  [base:call-with-pointer-array
   args
   [lambda
    (arr n)
    (LLVMBuildCleanupPad (builder-live-ptr b) parent-pad arr n name)]]]

 [define
  (build-catchret b catchpad dest-block)
  (LLVMBuildCatchRet (builder-live-ptr b) catchpad dest-block)]
 [define
  (build-cleanupret b cleanuppad unwind-block)
  [LLVMBuildCleanupRet
   (builder-live-ptr b)
   cleanuppad
   (or unwind-block base:null-ptr)]]

 [define
  build-callbr
  [case-lambda
   [(b fn-type fn default-block indirect-blocks args name)
    (build-callbr b fn-type fn default-block indirect-blocks args '() name)]
   [(b fn-type fn default-block indirect-blocks args bundles name)
    [base:call-with-pointer-array
     indirect-blocks
     [lambda
      (dests ndests)
      [base:call-with-pointer-array
       args
       [lambda
        (arr n)
        [base:call-with-pointer-array
         bundles
         [lambda
          (barr bn)
          [LLVMBuildCallBr
           (builder-live-ptr b)
           fn-type
           fn
           default-block
           dests
           ndests
           arr
           n
           barr
           bn
           name]]]]]]]]]]

 ;; a callable inline-asm value of the given function type
 [define
  [inline-asm
   fn-type
   asm-text
   constraints
   side-effects?
   align-stack?
   intel?
   can-throw?]
  [LLVMGetInlineAsm
   fn-type
   asm-text
   (bytevector-length (string->utf8 asm-text))
   constraints
   (bytevector-length (string->utf8 constraints))
   (if side-effects? 1 0)
   (if align-stack? 1 0)
   (if intel? 1 0)
   (if can-throw? 1 0)]]

 (define (token-type ctx) (LLVMTokenTypeInContext (context-live-ptr ctx)))

 [define
  build-freeze
  [case-lambda
   ((b v) (build-freeze b v ""))
   ((b v nm) (LLVMBuildFreeze (builder-live-ptr b) v nm))]]

 [define
  build-va-arg
  [case-lambda
   ((b va-list ty) (build-va-arg b va-list ty ""))
   ((b va-list ty nm) (LLVMBuildVAArg (builder-live-ptr b) va-list ty nm))]]

 [define
  build-extractelement
  [case-lambda
   ((b vec idx) (build-extractelement b vec idx ""))
   ((b vec idx nm) (LLVMBuildExtractElement (builder-live-ptr b) vec idx nm))]]
 [define
  build-insertelement
  [case-lambda
   ((b vec elt idx) (build-insertelement b vec elt idx ""))
   [(b vec elt idx nm)
    (LLVMBuildInsertElement (builder-live-ptr b) vec elt idx nm)]]]
 [define
  build-shufflevector           ; mask: a constant vector of i32
  [case-lambda
   ((b v1 v2 mask) (build-shufflevector b v1 v2 mask ""))
   [(b v1 v2 mask nm)
    (LLVMBuildShuffleVector (builder-live-ptr b) v1 v2 mask nm)]]]
 [define
  build-extractvalue
  [case-lambda
   ((b agg idx) (build-extractvalue b agg idx ""))
   ((b agg idx nm) (LLVMBuildExtractValue (builder-live-ptr b) agg idx nm))]]
 [define
  build-insertvalue
  [case-lambda
   ((b agg elt idx) (build-insertvalue b agg elt idx ""))
   [(b agg elt idx nm)
    (LLVMBuildInsertValue (builder-live-ptr b) agg elt idx nm)]]]

 ;; atomics; ordering/rmw-op arguments are the C enum ints. The C builders take
 ;; no name, so we name the result afterwards.
 [define
  (build-fence b ordering)
  (LLVMBuildFence (builder-live-ptr b) ordering 0 "")]
 [define
  (build-atomicrmw b rmw-op ptr val ordering name)
  (when (memv rmw-op '(15 16)) (config:require-capability! 'atomic-uinc-wrap))
  (when (memv rmw-op '(17 18)) (config:require-capability! 'atomic-usub))
  [let
   ((v (LLVMBuildAtomicRMW (builder-live-ptr b) rmw-op ptr val ordering 0)))
   (unless (string=? name "") (set-value-name! v name))
   v]]
 [define
  (build-cmpxchg b ptr cmp new succ-ord fail-ord name)
  [let
   [[v
     [LLVMBuildAtomicCmpXchg
      (builder-live-ptr b)
      ptr
      cmp
      new
      succ-ord
      fail-ord
      0]]]
   (unless (string=? name "") (set-value-name! v name))
   v]]

 (define (set-ordering! v ordering) (LLVMSetOrdering v ordering))
 ;; LLVMGetOrdering reads loads, stores and atomicrmw everywhere, but on LLVM 16
 ;; it casts a fence to atomicrmw and returns garbage (probed: acquire reads as
 ;; 2, seq_cst as 3); read fences from the printer there. Fences are built with
 ;; their ordering, so no setter is involved.
 [define
  ordering-words
  '[(unordered . 1)
    (monotonic . 2)
    (acquire   . 4)
    (release   . 5)
    (acq_rel   . 6)
    (seq_cst   . 7)]]
 (define fence-opcode 55)
 [define
  (instruction-ordering v)
  [if
   [or
    (config:capability? 'fence-ordering-accessor)
    (not (= (LLVMGetInstructionOpcode v) fence-opcode))]
   (LLVMGetOrdering v)
   [let*
    [(text (base:cstring->string/dispose (LLVMPrintValueToString v)))
     (p (open-string-input-port text))]
    [let
     loop
     ((last #f))
     [let
      ((tok (read p)))
      [if
       (eof-object? tok)
       [or
        [and
         (symbol? last)
         (cond ((assq last ordering-words) => cdr) (else #f))]
        (base:error 'ir:instruction-ordering "unreadable fence ordering" text)]
       (loop tok)]]]]]]
 (define (set-weak! v) (LLVMSetWeak v 1))
 (define (atomicrmw-binop v) (LLVMGetAtomicRMWBinOp v))
 (define (cmpxchg-success-ordering v) (LLVMGetCmpXchgSuccessOrdering v))
 (define (cmpxchg-failure-ordering v) (LLVMGetCmpXchgFailureOrdering v))

 [define-syntax
  define-binop
  [syntax-rules
   ()
   [(_ name raw)
    [define
     name
     [case-lambda
      ((b x y) (name b x y ""))
      ((b x y nm) (raw (builder-live-ptr b) x y nm))]]]]]

 (define-binop build-add LLVMBuildAdd)
 (define-binop build-sub LLVMBuildSub)
 (define-binop build-mul LLVMBuildMul)
 (define-binop build-sdiv LLVMBuildSDiv)
 (define-binop build-udiv LLVMBuildUDiv)
 (define-binop build-srem LLVMBuildSRem)
 (define-binop build-urem LLVMBuildURem)
 (define-binop build-and LLVMBuildAnd)
 (define-binop build-or LLVMBuildOr)
 (define-binop build-xor LLVMBuildXor)
 (define-binop build-shl LLVMBuildShl)
 (define-binop build-lshr LLVMBuildLShr)
 (define-binop build-ashr LLVMBuildAShr)
 (define-binop build-fadd LLVMBuildFAdd)
 (define-binop build-fsub LLVMBuildFSub)
 (define-binop build-fmul LLVMBuildFMul)
 (define-binop build-fdiv LLVMBuildFDiv)
 (define-binop build-frem LLVMBuildFRem)

 [define-syntax
  define-unop
  [syntax-rules
   ()
   [(_ name raw)
    [define
     name
     [case-lambda
      ((b x) (name b x ""))
      ((b x nm) (raw (builder-live-ptr b) x nm))]]]]]

 (define-unop build-neg LLVMBuildNeg)
 (define-unop build-fneg LLVMBuildFNeg)
 (define-unop build-not LLVMBuildNot)

 ;; LLVMIntPredicate values from llvm-c-19/Core.h.
 [define
  (int-predicate->int pred)
  [case
   pred
   ((eq) 32)
   ((ne) 33)
   ((ugt) 34)
   ((uge) 35)
   ((ult) 36)
   ((ule) 37)
   ((sgt) 38)
   ((sge) 39)
   ((slt) 40)
   ((sle) 41)
   (else (base:error 'ir:build-icmp "unknown integer predicate" pred))]]

 ;; LLVMRealPredicate values from llvm-c-19/Core.h.
 [define
  (real-predicate->int pred)
  [case
   pred
   ((false) 0)
   ((oeq) 1)
   ((ogt) 2)
   ((oge) 3)
   ((olt) 4)
   ((ole) 5)
   ((one) 6)
   ((ord) 7)
   ((uno) 8)
   ((ueq) 9)
   ((ugt) 10)
   ((uge) 11)
   ((ult) 12)
   ((ule) 13)
   ((une) 14)
   ((true) 15)
   (else (base:error 'ir:build-fcmp "unknown real predicate" pred))]]

 [define
  build-icmp
  [case-lambda
   ((b pred x y) (build-icmp b pred x y ""))
   [(b pred x y nm)
    (LLVMBuildICmp (builder-live-ptr b) (int-predicate->int pred) x y nm)]]]

 [define
  build-fcmp
  [case-lambda
   ((b pred x y) (build-fcmp b pred x y ""))
   [(b pred x y nm)
    (LLVMBuildFCmp (builder-live-ptr b) (real-predicate->int pred) x y nm)]]]

 [define
  build-select
  [case-lambda
   ((b c t f) (build-select b c t f ""))
   ((b c t f nm) (LLVMBuildSelect (builder-live-ptr b) c t f nm))]]

 [define
  build-phi
  [case-lambda
   ((b ty) (build-phi b ty ""))
   ((b ty nm) (LLVMBuildPhi (builder-live-ptr b) ty nm))]]

 ;; incoming: list of (value . block) pairs.
 [define
  (phi-add-incoming! phi incoming)
  [base:call-with-pointer-array
   (map car incoming)
   [lambda
    (vals n)
    [base:call-with-pointer-array
     (map cdr incoming)
     (lambda (blocks n2) (LLVMAddIncoming phi vals blocks n))]]]]

 [define
  build-call
  [case-lambda
   ((b fn-type fn args) (build-call b fn-type fn args ""))
   [(b fn-type fn args nm)
    [base:call-with-pointer-array
     args
     [lambda
      (arr n)
      (LLVMBuildCall2 (builder-live-ptr b) fn-type fn arr n nm)]]]]]

 [define
  build-alloca
  [case-lambda
   ((b ty) (build-alloca b ty ""))
   ((b ty nm) (LLVMBuildAlloca (builder-live-ptr b) ty nm))]]

 [define
  build-array-alloca
  [case-lambda
   ((b ty count) (build-array-alloca b ty count ""))
   ((b ty count nm) (LLVMBuildArrayAlloca (builder-live-ptr b) ty count nm))]]

 ;; LLVMTailCallKind ints: 0 none, 1 tail, 2 musttail, 3 notail. Before LLVM 18
 ;; the C API has only the `tail` boolean; musttail/notail are refused when
 ;; setting and read back from the printer.
 [define
  (set-tail-call-kind! call-inst kind)
  [cond
   ((config:capability? 'tail-call-kinds) (LLVMSetTailCallKind call-inst kind))
   ((memv kind '(0 1)) (LLVMSetTailCall call-inst kind))
   (else (config:require-capability! 'tail-call-kinds))]]
 [define
  (tail-call-kind call-inst)
  [cond
   ((config:capability? 'tail-call-kinds) (LLVMGetTailCallKind call-inst))
   ((text:leading-flag? call-inst 'musttail) 2)
   ((text:leading-flag? call-inst 'notail) 3)
   ((not (zero? (LLVMIsTailCall call-inst))) 1)
   (else 0)]]
 (define (set-function-call-conv! f cc) (LLVMSetFunctionCallConv f cc))
 (define (function-call-conv f) (LLVMGetFunctionCallConv f))
 [define
  (set-instruction-call-conv! call-inst cc)
  (LLVMSetInstructionCallConv call-inst cc)]
 [define
  (instruction-call-conv call-inst)
  (LLVMGetInstructionCallConv call-inst)]

 ;; ---- attributes -------------------------------------------------------

 (define attr-function-index 4294967295) ; LLVMAttributeIndex ~0U

 ;; 0 = LLVM has no enum attribute of this name
 [define
  (enum-attribute-kind-named name)
  (LLVMGetEnumAttributeKindForName name (string-length name))]

 [define
  (create-enum-attribute ctx kind value)
  (LLVMCreateEnumAttribute (context-live-ptr ctx) kind value)]

 [define
  (create-string-attribute ctx k v)
  [let
   ((kb (string->utf8 k)) (vb (string->utf8 v)))
   [LLVMCreateStringAttribute
    (context-live-ptr ctx)
    k
    (bytevector-length kb)
    v
    (bytevector-length vb)]]]

 [define
  (add-function-attribute! f attr)
  (LLVMAddAttributeAtIndex f attr-function-index attr)]

 [define
  (add-callsite-attribute! call-inst attr)
  (LLVMAddCallSiteAttribute call-inst attr-function-index attr)]

 ;; the function-position attributes as a list of AttributeRefs
 [define
  (function-attributes f)
  [let
   ((n (LLVMGetAttributeCountAtIndex f attr-function-index)))
   [if
    (zero? n)
    '()
    [let
     ((buf (foreign-alloc (* 8 n))))
     (LLVMGetAttributesAtIndex f attr-function-index buf)
     [let
      loop
      ((i (- n 1)) (acc '()))
      [if
       (< i 0)
       (begin (foreign-free buf) acc)
       (loop (- i 1) (cons (foreign-ref 'void* buf (* 8 i)) acc))]]]]]]

 ;; the function-position attributes of a CALL SITE, same shape
 [define
  (callsite-attributes call-inst)
  [let
   ((n (LLVMGetCallSiteAttributeCount call-inst attr-function-index)))
   [if
    (zero? n)
    '()
    [let
     ((buf (foreign-alloc (* 8 n))))
     (LLVMGetCallSiteAttributes call-inst attr-function-index buf)
     [let
      loop
      ((i (- n 1)) (acc '()))
      [if
       (< i 0)
       (begin (foreign-free buf) acc)
       (loop (- i 1) (cons (foreign-ref 'void* buf (* 8 i)) acc))]]]]]]

 ;; probed: LLVMIsEnumAttribute is TRUE for int-VALUED attributes too
 ;; (alignstack(8), uwtable(2), ...), and value 0 does not mean valueless
 ;; (memory(none) has value 0) -- classify by a table of known-valueless kinds,
 ;; never by value alone. Type attributes also carry an enum kind -- test
 ;; attribute-type? first.
 (define (attribute-enum? a) (not (zero? (LLVMIsEnumAttribute a))))
 (define (attribute-string? a) (not (zero? (LLVMIsStringAttribute a))))
 (define (attribute-type? a) (not (zero? (LLVMIsTypeAttribute a))))
 (define (attribute-enum-kind a) (LLVMGetEnumAttributeKind a))
 (define (attribute-enum-value a) (LLVMGetEnumAttributeValue a))

 [define
  (string-with-len-out getter a)
  [let
   ((out (foreign-alloc 4)))
   [let
    ((p (getter a out)))
    [let
     ((s (base:cstring->string/len p (foreign-ref 'unsigned-32 out 0))))
     (foreign-free out)
     s]]]]

 [define
  (attribute-string-kind a)
  (string-with-len-out LLVMGetStringAttributeKind a)]
 [define
  (attribute-string-value a)
  (string-with-len-out LLVMGetStringAttributeValue a)]

 ;; surgery used for forward-reference patching
 (define (replace-all-uses! old new) (LLVMReplaceAllUsesWith old new))
 (define (erase-instruction! inst) (LLVMInstructionEraseFromParent inst))
 (define (delete-block! bb) (LLVMDeleteBasicBlock bb))

 [define
  build-load
  [case-lambda
   ((b ty ptr) (build-load b ty ptr ""))
   ((b ty ptr nm) (LLVMBuildLoad2 (builder-live-ptr b) ty ptr nm))]]

 (define (build-store b v ptr) (LLVMBuildStore (builder-live-ptr b) v ptr))

 [define
  build-gep
  [case-lambda
   ((b elem-ty ptr indices) (build-gep b elem-ty ptr indices ""))
   [(b elem-ty ptr indices nm)
    [base:call-with-pointer-array
     indices
     [lambda
      (arr n)
      (LLVMBuildGEP2 (builder-live-ptr b) elem-ty ptr arr n nm)]]]]]

 ;; flags: LLVMGEPNoWrapFlags bitmask (inbounds/nusw/nuw)
 [define
  build-gep/flags
  [case-lambda
   [(b elem-ty ptr indices flags)
    (build-gep/flags b elem-ty ptr indices flags "")]
   [(b elem-ty ptr indices flags nm)
    (require-gep-flags! flags)
    [base:call-with-pointer-array
     indices
     [lambda
      (arr n)
      [cond
       [(config:capability? 'gep-no-wrap-flags)
        [LLVMBuildGEPWithNoWrapFlags
         (builder-live-ptr b)
         elem-ty
         ptr
         arr
         n
         nm
         flags]]
       ((zero? flags) (LLVMBuildGEP2 (builder-live-ptr b) elem-ty ptr arr n nm))
       [else
        (LLVMBuildInBoundsGEP2 (builder-live-ptr b) elem-ty ptr arr n nm)]]]]]]]

 [define-syntax
  define-cast
  [syntax-rules
   ()
   [(_ name raw)
    [define
     name
     [case-lambda
      ((b v ty) (name b v ty ""))
      ((b v ty nm) (raw (builder-live-ptr b) v ty nm))]]]]]

 (define-cast build-trunc LLVMBuildTrunc)
 (define-cast build-zext LLVMBuildZExt)
 (define-cast build-sext LLVMBuildSExt)
 (define-cast build-si->fp LLVMBuildSIToFP)
 (define-cast build-ui->fp LLVMBuildUIToFP)
 (define-cast build-fp->si LLVMBuildFPToSI)
 (define-cast build-fp->ui LLVMBuildFPToUI)
 (define-cast build-fptrunc LLVMBuildFPTrunc)
 (define-cast build-fpext LLVMBuildFPExt)
 (define-cast build-ptr->int LLVMBuildPtrToInt)
 (define-cast build-int->ptr LLVMBuildIntToPtr)
 (define-cast build-bitcast LLVMBuildBitCast)
 (define-cast build-addrspacecast LLVMBuildAddrSpaceCast)]
