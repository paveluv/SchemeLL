;;; (llvm jit) -- layer 2: ORC LLJIT. Compile LLVM modules fully in memory
;;; and expose JIT'd functions as ordinary Scheme procedures.
;;;
;;; Usage sketch:
;;;   (define jc (make-jit-context))
;;;   (define m (make-module (jit-context-context jc) "m"))
;;;   ... build IR in m ...
;;;   (define j (make-jit))
;;;   (jit-add-module! j jc m)        ; m is consumed here
;;;   (define f (jit-function j "add"))
;;;   (f 3 4)
;;;
;;; Lifetime rules:
;;;   - Modules added to the JIT are consumed (their record raises on reuse).
;;;   - Procedures from jit-function close over the jit record, so the JIT
;;;     (and its executable memory) stays alive while any of them is
;;;     reachable. Unreachable jits are disposed lazily by a guardian.
;;;   - Function signatures are captured at add-module time (the IR is
;;;     inaccessible afterwards), so jit-function needs no type annotations.
(library (llvm jit)
  (export jit? make-jit jit-dispose!
          jit-context? make-jit-context jit-context-context jit-context-dispose!
          jit-add-module! jit-lookup-address jit-function)
  (import (chezscheme) (llvm raw) (llvm base) (llvm ir) (llvm target))

  ;; ---- jit contexts (ORC ThreadSafeContext) -------------------------------

  (define-record-type (jit-context $make-jit-context jit-context?)
    (fields tsctx context (mutable state))
    (nongenerative llvm-jit-context-v0))

  ;; Modules destined for a JIT must be built in a context owned by an ORC
  ;; ThreadSafeContext; jit-context-context gives the (borrowed) context
  ;; record to pass to make-module.
  (define (make-jit-context)
    (let ([tsctx (LLVMOrcCreateNewThreadSafeContext)])
      ($make-jit-context tsctx
                         (wrap-context (LLVMOrcThreadSafeContextGetContext tsctx))
                         'owned)))

  (define (jit-context-live-tsctx jc)
    (unless (eq? (jit-context-state jc) 'owned)
      (llvm-error 'jit-context "jit-context is no longer live"
                  (jit-context-state jc)))
    (jit-context-tsctx jc))

  ;; Safe to call once the modules built in this context have been added to
  ;; a JIT: the ThreadSafeContext is refcounted and stays alive underneath.
  ;; Do NOT call while an un-added module still uses the context.
  (define (jit-context-dispose! jc)
    (when (eq? (jit-context-state jc) 'owned)
      (LLVMOrcDisposeThreadSafeContext (jit-context-tsctx jc))
      (context-dispose! (jit-context-context jc))
      (jit-context-state-set! jc 'disposed)))

  ;; ---- the JIT itself --------------------------------------------------------

  (define-record-type (jit $make-jit jit?)
    (fields ptr dylib signatures (mutable state))
    (nongenerative llvm-jit-v0))

  ;; Dispose jits that became unreachable (their generated procedures keep
  ;; them reachable, so this never frees code that can still be called).
  (define jit-guardian (make-guardian))

  (define (sweep-dead-jits!)
    (let loop ()
      (let ([j (jit-guardian)])
        (when j
          (jit-dispose! j)
          (loop)))))

  (define (make-jit)
    (sweep-dead-jits!)
    (initialize-native-target!)
    (let-values ([(err ptr)
                  (call-with-out-ptr
                   (lambda (out) (LLVMOrcCreateLLJIT out null-ptr)))])
      (check-error-ref 'make-jit err)
      (let ([j ($make-jit ptr
                          (LLVMOrcLLJITGetMainJITDylib ptr)
                          (make-hashtable string-hash string=?)
                          'owned)])
        (jit-guardian j)
        j)))

  (define (jit-live-ptr j)
    (unless (eq? (jit-state j) 'owned)
      (llvm-error 'jit "jit is no longer live" (jit-state j)))
    (jit-ptr j))

  (define (jit-dispose! j)
    (when (eq? (jit-state j) 'owned)
      (jit-state-set! j 'disposed)
      (let ([err (LLVMOrcDisposeLLJIT (jit-ptr j))])
        ;; may run from the guardian sweep; swallow rather than raise
        (unless (null-ptr? err) (LLVMConsumeError err)))))

  ;; ---- signature capture -------------------------------------------------------

  ;; Map an LLVM type to a Chez foreign-procedure type; #f if unsupported
  ;; (aggregates by value, vectors, ...).
  (define (llvm-type->foreign-type t)
    (case (type-kind t)
      [(void) 'void]
      [(integer)
       (case (type-int-width t)
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
    (let ([ft (function-type-of f)])
      (if (type-vararg? ft)
          '(unsupported . "vararg functions are not callable via jit-function")
          (let ([ret (llvm-type->foreign-type (type-return-type ft))]
                [args (map llvm-type->foreign-type (type-param-types ft))])
            (if (and ret (for-all values args))
                (cons ret args)
                (cons 'unsupported "parameter or return type not representable in Chez FFI"))))))

  (define (capture-signatures! j m)
    (let ([sigs (jit-signatures j)])
      (let loop ([f (LLVMGetFirstFunction (module-live-ptr m))])
        (unless (null-ptr? f)
          (unless (declaration? f)
            (hashtable-set! sigs (value-name f) (function-signature f)))
          (loop (LLVMGetNextFunction f))))))

  ;; ---- adding modules and looking up code ----------------------------------------

  (define (jit-add-module! j jc m)
    (unless (eqv? (context-live-ptr (module-context m))
                  (context-live-ptr (jit-context-context jc)))
      (llvm-error 'jit-add-module!
                  "module was not created in this jit-context" m jc))
    (capture-signatures! j m)
    (let ([mod-ptr (module-live-ptr m)]
          [tsctx (jit-context-live-tsctx jc)])
      (module-consume! m)
      (let ([tsm (LLVMOrcCreateNewThreadSafeModule mod-ptr tsctx)])
        ;; AddLLVMIRModule consumes tsm even on error
        (check-error-ref 'jit-add-module!
                         (LLVMOrcLLJITAddLLVMIRModule
                          (jit-live-ptr j) (jit-dylib j) tsm)))))

  ;; Raw entry-point address of a JIT'd function (triggers compilation).
  (define (jit-lookup-address j name)
    (let-values ([(err addr)
                  (call-with-out-ptr
                   (lambda (out)
                     (LLVMOrcLLJITLookup (jit-live-ptr j) out name)))])
      (check-error-ref 'jit-lookup-address err)
      addr))

  ;; The payoff: a JIT'd function as a ready-to-call Scheme procedure, with
  ;; the foreign signature derived from the function's LLVM type.
  (define (jit-function j name)
    (let ([sig (hashtable-ref (jit-signatures j) name #f)])
      (cond
        [(not sig)
         (llvm-error 'jit-function "function not defined in any added module" name)]
        [(eq? (car sig) 'unsupported)
         (llvm-error 'jit-function (cdr sig) name)]
        [else
         (let* ([addr (jit-lookup-address j name)]
                [fp (eval `(foreign-procedure ,addr ,(cdr sig) ,(car sig))
                          (environment '(chezscheme)))])
           (lambda args
             ;; liveness check; also keeps j reachable from this closure
             (jit-live-ptr j)
             (apply fp args)))]))))
