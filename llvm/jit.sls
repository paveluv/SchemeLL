;;; (llvm jit) -- layer 2: ORC LLJIT. Compile LLVM modules fully in memory
;;; and expose JIT'd functions as ordinary Scheme procedures.
;;;
;;; This library is designed to be imported with a prefix:
;;;   (import (prefix (llvm jit) jit:))
;;; so definitions carry no jit- prefix of their own (make, function,
;;; add-module!, ...). As everywhere in this project, all project libraries
;;; are imported prefixed (see project/RULES.md).
;;;
;;; Usage sketch:
;;;   (define jc (jit:make-context))
;;;   (define m (ir:make-module (jit:context-ir jc) "m"))
;;;   ... build IR in m ...
;;;   (define j (jit:make))
;;;   (jit:add-module! j jc m)        ; m is consumed here
;;;   (define f (jit:function j "add"))
;;;   (f 3 4)
;;;
;;; Lifetime rules:
;;;   - Modules added to the JIT are consumed (their record raises on reuse).
;;;   - Procedures from jit:function close over the jit record, so the JIT
;;;     (and its executable memory) stays alive while any of them is
;;;     reachable. Unreachable jits are disposed lazily by a guardian.
;;;   - Function signatures are captured at add-module! time (the IR is
;;;     inaccessible afterwards), so jit:function needs no type annotations.
(library (llvm jit)
  (export jit? make dispose!
          context? make-context context-ir context-dispose!
          add-module! lookup-address function stackmap-address)
  (import (chezscheme) (prefix (llvm raw) LLVM) (prefix (llvm base) base:)
          (prefix (llvm ir) ir:)
          (prefix (llvm target) target:))

  ;; ---- jit contexts (ORC ThreadSafeContext) -------------------------------

  (define-record-type (jit-context $make-context context?)
    (fields (immutable tsctx context-tsctx)
            (immutable ir context-ir)
            (mutable state context-state context-state-set!))
    (nongenerative llvm-jit-context-v0))

  ;; Modules destined for a JIT must be built in a context owned by an ORC
  ;; ThreadSafeContext; context-ir gives the (borrowed) (llvm ir) context
  ;; record to pass to ir:make-module.
  (define (make-context)
    (let ([tsctx (LLVMOrcCreateNewThreadSafeContext)])
      ($make-context tsctx
                     (ir:wrap-context (LLVMOrcThreadSafeContextGetContext tsctx))
                     'owned)))

  (define (context-live-tsctx jc)
    (unless (eq? (context-state jc) 'owned)
      (base:error 'jit-context "jit context is no longer live"
                  (context-state jc)))
    (context-tsctx jc))

  ;; Safe to call once the modules built in this context have been added to
  ;; a JIT: the ThreadSafeContext is refcounted and stays alive underneath.
  ;; Do NOT call while an un-added module still uses the context.
  (define (context-dispose! jc)
    (when (eq? (context-state jc) 'owned)
      (LLVMOrcDisposeThreadSafeContext (context-tsctx jc))
      (ir:context-dispose! (context-ir jc))
      (context-state-set! jc 'disposed)))

  ;; ---- the JIT itself --------------------------------------------------------

  (define-record-type (jit $make-jit jit?)
    (fields (immutable ptr jit-ptr)
            (immutable dylib jit-dylib)
            (immutable signatures jit-signatures)
            (mutable state jit-state jit-state-set!))
    (nongenerative llvm-jit-v0))

  ;; Dispose jits that became unreachable (their generated procedures keep
  ;; them reachable, so this never frees code that can still be called).
  (define jit-guardian (make-guardian))

  (define (sweep-dead-jits!)
    (let loop ()
      (let ([j (jit-guardian)])
        (when j
          (dispose! j)
          (loop)))))

  ;; (make)           -> an LLJIT with LLVM's default target machine
  ;;                     (codegen at the default level, -O2)
  ;; (make opt-level) -> one whose codegen runs at OPT-LEVEL (none,
  ;;                     less, default, aggressive): a host-default
  ;;                     target machine at that level rides a JIT
  ;;                     target machine builder, which the LLJIT
  ;;                     builder takes; LLVMOrcCreateLLJIT consumes
  ;;                     the builder and the machine with it (the
  ;;                     machine record is simply dropped). 'none is
  ;;                     FastISel: code that runs a few times -- a
  ;;                     compiler's meta level -- need not pay -O2
  ;;                     codegen (MeikScheme M11/S2).
  (define make
    (case-lambda
      [() (make #f)]
      [(opt-level)
       (sweep-dead-jits!)
       (target:initialize-native!)
       (let ([builder
              (if opt-level
                  (let ([b (LLVMOrcCreateLLJITBuilder)]
                        [tm (target:make-machine (target:default-triple)
                                                 (target:host-cpu-name)
                                                 (target:host-cpu-features)
                                                 opt-level)])
                    (LLVMOrcLLJITBuilderSetJITTargetMachineBuilder
                      b (LLVMOrcJITTargetMachineBuilderCreateFromTargetMachine
                          (target:machine-live-ptr tm)))
                    b)
                  base:null-ptr)])
         (make-with-builder builder))]))
  (define (make-with-builder builder)
    (let-values ([(err ptr)
                  (base:call-with-out-ptr
                    (lambda (out) (LLVMOrcCreateLLJIT out builder)))])
      (base:check-error-ref 'jit:make err)
      (let ([j ($make-jit ptr
                          (LLVMOrcLLJITGetMainJITDylib ptr)
                          (make-hashtable string-hash string=?)
                          'owned)])
        ;; resolve process symbols (libc, the Scheme runtime, ...) so
        ;; JIT'd code may call declared externals
        (let-values ([(err gen)
                      (base:call-with-out-ptr
                        (lambda (out)
                          (LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess
                            out (LLVMOrcLLJITGetGlobalPrefix ptr)
                            base:null-ptr base:null-ptr)))])
          (base:check-error-ref 'jit:make err)
          (LLVMOrcJITDylibAddGenerator (jit-dylib j) gen))
        (jit-guardian j)
        j)))

  (define (jit-live-ptr j)
    (unless (eq? (jit-state j) 'owned)
      (base:error 'jit "jit is no longer live" (jit-state j)))
    (jit-ptr j))

  (define (dispose! j)
    (when (eq? (jit-state j) 'owned)
      (jit-state-set! j 'disposed)
      (let ([err (LLVMOrcDisposeLLJIT (jit-ptr j))])
        ;; may run from the guardian sweep; swallow rather than raise
        (unless (base:null-ptr? err) (LLVMConsumeError err)))))

  ;; ---- signature capture -------------------------------------------------------

  ;; Map an LLVM type to a Chez foreign-procedure type; #f if unsupported
  ;; (aggregates by value, vectors, ...).
  (define (llvm-type->foreign-type t)
    (case (ir:type-kind t)
      [(void) 'void]
      [(integer)
       (case (ir:type-int-width t)
         ;; i1: relies on LLVM materializing 0/1 in the return register
         [(1) 'boolean]
         [(8) 'integer-8] [(16) 'integer-16]
         [(32) 'integer-32] [(64) 'integer-64]
         [else #f])]
      [(float) 'float]
      [(double) 'double]
      [(pointer) 'void*]
      [else #f]))

  ;; sig: (ret-type . arg-types) | (unsupported . reason)
  (define (function-signature f)
    (let ([ft (ir:function-type-of f)])
      (if (ir:type-vararg? ft)
          '(unsupported . "vararg functions are not callable via jit:function")
          (let ([ret (llvm-type->foreign-type (ir:type-return-type ft))]
                [args (map llvm-type->foreign-type (ir:type-param-types ft))])
            (if (and ret (for-all values args))
                (cons ret args)
                (cons 'unsupported "parameter or return type not representable in Chez FFI"))))))

  (define (capture-signatures! j m)
    (let ([sigs (jit-signatures j)])
      (let loop ([f (LLVMGetFirstFunction (ir:module-live-ptr m))])
        (unless (base:null-ptr? f)
          (unless (ir:declaration? f)
            (hashtable-set! sigs (ir:value-name f) (function-signature f)))
          (loop (LLVMGetNextFunction f))))))

  ;; ---- adding modules and looking up code ----------------------------------------

  ;; the arch and OS components of a target triple, for host matching
  ;; (the vendor field is irrelevant: -pc- and -unknown- are the same
  ;; machine)
  (define (triple-arch t)
    (let loop ([i 0])
      (cond
        [(= i (string-length t)) t]
        [(char=? (string-ref t i) #\-) (substring t 0 i)]
        [else (loop (+ i 1))])))

  (define os-keywords
    '("linux" "darwin" "macos" "windows" "freebsd" "netbsd" "openbsd"
      "solaris" "wasi"))

  (define (triple-os t)
    (find (lambda (os)
            (let ([n (string-length t)] [m (string-length os)])
              (let loop ([i 0])
                (cond
                  [(> (+ i m) n) #f]
                  [(string=? (substring t i (+ i m)) os) #t]
                  [else (loop (+ i 1))]))))
          os-keywords))

  (define (add-module! j jc m)
    (unless (eqv? (ir:context-live-ptr (ir:module-context m))
                  (ir:context-live-ptr (context-ir jc)))
      (base:error 'jit:add-module!
                  "module was not created in this jit context" m jc))
    ;; the JIT compiles for THIS machine: a module declaring a foreign
    ;; target would produce code that cannot run here
    (let ([mt (base:cstring->string
                (LLVMGetTarget (ir:module-live-ptr m)))]
          [host (target:default-triple)])
      (when (and mt (not (string=? mt "")))
        (unless (and (string=? (triple-arch mt) (triple-arch host))
                     (equal? (triple-os mt) (triple-os host)))
          (base:error 'jit:add-module!
            "module targets a different platform than this JIT's host"
            mt host))))
    (capture-signatures! j m)
    (let ([mod-ptr (ir:module-live-ptr m)]
          [tsctx (context-live-tsctx jc)])
      (ir:module-consume! m)
      (let ([tsm (LLVMOrcCreateNewThreadSafeModule mod-ptr tsctx)])
        ;; AddLLVMIRModule consumes tsm even on error
        (base:check-error-ref 'jit:add-module!
                              (LLVMOrcLLJITAddLLVMIRModule
                                (jit-live-ptr j) (jit-dylib j) tsm)))))

  ;; Raw entry-point address of a JIT'd function (triggers compilation).
  (define (lookup-address j name)
    (let-values ([(err addr)
                  (base:call-with-out-ptr
                    (lambda (out)
                      (LLVMOrcLLJITLookup (jit-live-ptr j) out name)))])
      (base:check-error-ref 'jit:lookup-address err)
      ;; materialization just ran: inline-asm parse errors report
      ;; success + an error-severity diagnostic
      (base:check-diagnostics! 'jit:lookup-address)
      addr))

  ;; The payoff: a JIT'd function as a ready-to-call Scheme procedure, with
  ;; the foreign signature derived from the function's LLVM type.
  (define (function j name)
    (let ([sig (hashtable-ref (jit-signatures j) name #f)])
      (cond
        [(not sig)
         (base:error 'jit:function "function not defined in any added module" name)]
        [(eq? (car sig) 'unsupported)
         (base:error 'jit:function (cdr sig) name)]
        [else
         (let* ([addr (lookup-address j name)]
                [fp (eval `(foreign-procedure ,addr ,(cdr sig) ,(car sig))
                          (environment '(chezscheme)))])
           (lambda args
             ;; liveness check; also keeps j reachable from this closure
             (jit-live-ptr j)
             (apply fp args)))])))

  ;; Run-time address of the JIT'd module's .llvm_stackmaps section
  ;; (GC statepoint stack maps). Codegen's section symbol
  ;; (__LLVM_StackMaps) is LOCAL, so ORC lookup cannot see it (probed);
  ;; a program that needs its map at run time splices sll's
  ;; stackmap-keeper items, which export a pointer to the section under
  ;; a name this looks up. The direct name is still tried first in case
  ;; a linking-layer configuration ever exports it.
  ;; Multi-module programs: one keeper NAME per module (the dylib
  ;; holds one definition per symbol), created with
  ;; sll:stackmap-keeper-named and read back here by that name.
  (define stackmap-address
    (case-lambda
      [(j) (stackmap-address j "sll_stackmaps_keeper")]
      [(j keeper-name)
       (define (try name)
         (guard (e [#t #f]) (lookup-address j name)))
       (let ([keeper-name (if (symbol? keeper-name)
                              (symbol->string keeper-name)
                              keeper-name)])
         (cond
           [(try "__LLVM_StackMaps")]
           [(try keeper-name) =>
            (lambda (keeper) (foreign-ref 'void* keeper 0))]
           [else
            (base:error 'jit:stackmap-address
              "stack maps are not reachable: splice sll:stackmap-keeper (or stackmap-keeper-named, multi-module) into the program"
              keeper-name)]))])))
