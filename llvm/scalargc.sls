#!chezscheme
;;; (llvm scalargc) -- scalarize GC-bearing aggregates before
;;; statepoint rewriting. RewriteStatepointsForGC relocates POINTERS;
;;; it does not (by design) relocate first-class aggregates that
;;; contain gc pointers, and the safepoint verifier rejects any such
;;; aggregate live across a statepoint. Frontend IR is safe by
;;; construction -- multi-value returns are extracted in the same
;;; block, immediately -- but O2 re-forms the hazard: loop rotation +
;;; LCSSA build STRUCT-typed phis, and GVN/sinking move extractvalues
;;; away from their defs, leaving {gc-ptr, ...} values live across
;;; calls. (First surfaced by MeikScheme M3/S4's capture shapes; the
;;; exposure is generic to any struct-returning call convention.)
;;;
;;; The repair, run between O2 and RS4GC:
;;;   1. Split every struct phi whose type carries a gc-space member
;;;      into per-member phis (incoming values are extracted ADJACENT
;;;      to their defs, where no statepoint can intervene), rebuild
;;;      the aggregate at the phi point for any non-extract user, and
;;;      erase the struct phi.
;;;   2. Re-anchor every extractvalue of a gc-bearing struct next to
;;;      its def; rebuild the aggregate immediately before any other
;;;      user (ret, insertvalue) in a different block.
;;; After the pass, gc-bearing aggregates are consumed where they are
;;; produced; only SCALAR gc pointers cross statepoints, which RS4GC
;;; relocates correctly. Unhandled aggregate users (select, call
;;; arguments, loads) raise loudly -- a compile failure, never a
;;; wrong answer.
(library (llvm scalargc)
  (export scalarize-gc-aggregates!)
  (import (except (chezscheme) error)
          (prefix (llvm raw) LLVM)
          (prefix (llvm base) base:)
          (prefix (llvm ir) ir:))

  (define (error msg . irritants)
    (apply base:error 'scalargc:scalarize-gc-aggregates! msg irritants))

  ;; LLVMOpcode values (cross-checked by the coverage suite's header
  ;; oracle, as in (llvm gccheck))
  (define op-phi 44)
  (define op-call 45)
  (define op-extractvalue 53)
  (define op-insertvalue 54)

  (define (value->text v)
    (base:cstring->string/dispose (LLVMPrintValueToString v)))

  (define (users v)
    (let loop ([u (LLVMGetFirstUse v)] [acc '()])
      (if (base:null-ptr? u)
          (reverse acc)
          (loop (LLVMGetNextUse u) (cons (LLVMGetUser u) acc)))))

  (define (instruction? v)
    (not (base:null-ptr? (LLVMIsAInstruction v))))

  (define (block-instructions bb)
    (let loop ([i (LLVMGetFirstInstruction bb)] [acc '()])
      (if (base:null-ptr? i)
          (reverse acc)
          (loop (LLVMGetNextInstruction i) (cons i acc)))))

  (define (extract-index e)
    (unless (= (LLVMGetNumIndices e) 1)
      (error "multi-index extractvalue is not ours" (value->text e)))
    (foreign-ref 'unsigned-32 (LLVMGetIndices e) 0))

  (define (scalarize-gc-aggregates! m gcspace)
    (let* ([ctx (ir:module-context m)]
           [kind-struct (LLVMGetTypeKind
                          (ir:struct-type ctx (list (ir:int64-type ctx))))]
           [kind-ptr (LLVMGetTypeKind (ir:pointer-type ctx gcspace))]
           [bld (LLVMCreateBuilderInContext (ir:context-live-ptr ctx))]
           ;; memo: (def-address . index) -> the adjacent extract
           [memo (make-hashtable equal-hash equal?)])

      (define (gc-struct-type? ty)
        (and (= (LLVMGetTypeKind ty) kind-struct)
             (let ([n (LLVMCountStructElementTypes ty)])
               (let loop ([i 0])
                 (and (< i n)
                      (or (let ([et (LLVMStructGetTypeAtIndex ty i)])
                            (and (= (LLVMGetTypeKind et) kind-ptr)
                                 (= (LLVMGetPointerAddressSpace et)
                                    gcspace)))
                          (loop (+ i 1))))))))

      ;; position the builder where an extract of V is statepoint-safe:
      ;; right after V's def (after the phi group when V is a phi)
      (define (position-after-def! v)
        (if (= (LLVMGetInstructionOpcode v) op-phi)
            (let loop ([i (LLVMGetFirstInstruction
                            (LLVMGetInstructionParent v))])
              (if (= (LLVMGetInstructionOpcode i) op-phi)
                  (loop (LLVMGetNextInstruction i))
                  (LLVMPositionBuilderBefore bld i)))
            (let ([nx (LLVMGetNextInstruction v)])
              (when (base:null-ptr? nx)
                (error "aggregate def is a terminator" (value->text v)))
              (LLVMPositionBuilderBefore bld nx))))

      ;; member I of aggregate V, materialized adjacent to V's def
      ;; (constants fold; instructions are memoized so repeated
      ;; requests share one extract)
      (define (member-of v i)
        (if (instruction? v)
            (let ([key (cons v i)])
              (or (hashtable-ref memo key #f)
                  (begin
                    (position-after-def! v)
                    (let ([e (LLVMBuildExtractValue bld v i "sg")])
                      (hashtable-set! memo key e)
                      e))))
            ;; constant aggregate (undef etc.): the builder folds
            ;; without inserting, so position is irrelevant
            (LLVMBuildExtractValue bld v i "sg")))

      ;; rebuild the whole aggregate from member values, at the
      ;; current builder position
      (define (rebuild ty members)
        (let loop ([ms members] [i 0] [acc (LLVMGetUndef ty)])
          (if (null? ms)
              acc
              (loop (cdr ms) (+ i 1)
                    (LLVMBuildInsertValue
                      bld acc (car ms) i "sr")))))

      (define (members-of v ty)
        (let ([n (LLVMCountStructElementTypes ty)])
          (let loop ([i (- n 1)] [acc '()])
            (if (< i 0) acc (loop (- i 1) (cons (member-of v i) acc))))))

      ;; ---- phase 1: split gc-bearing struct phis -------------------
      (define (collect-struct-phis f)
        (let floop ([bb (LLVMGetFirstBasicBlock f)] [acc '()])
          (if (base:null-ptr? bb)
              (reverse acc)
              (floop (LLVMGetNextBasicBlock bb)
                     (let iloop ([i (LLVMGetFirstInstruction bb)]
                                 [acc acc])
                       (if (or (base:null-ptr? i)
                               (not (= (LLVMGetInstructionOpcode i)
                                       op-phi)))
                           acc
                           (iloop (LLVMGetNextInstruction i)
                                  (if (gc-struct-type? (LLVMTypeOf i))
                                      (cons i acc)
                                      acc))))))))

      (define (split-phi! p)
        (let* ([ty (LLVMTypeOf p)]
               [n (LLVMCountStructElementTypes ty)]
               [nin (LLVMCountIncoming p)])
          (LLVMPositionBuilderBefore bld p)
          (let ([mphis
                 (let loop ([i (- n 1)] [acc '()])
                   (if (< i 0)
                       acc
                       (loop (- i 1)
                             (cons (LLVMBuildPhi
                                     bld
                                     (LLVMStructGetTypeAtIndex ty i)
                                     "sgp")
                                   acc))))])
            (do ([j 0 (+ j 1)]) ((= j nin))
              (let ([v (LLVMGetIncomingValue p j)]
                    [blk (LLVMGetIncomingBlock p j)])
                (do ([i 0 (+ i 1)]) ((= i n))
                  (let ([mv (if (eqv? v p)   ; self-loop: the member
                                (list-ref mphis i)
                                (member-of v i))])
                    (base:call-with-pointer-array (list mv)
                      (lambda (varr vn)
                        (base:call-with-pointer-array (list blk)
                          (lambda (barr bn)
                            (LLVMAddIncoming (list-ref mphis i)
                                             varr barr 1)))))))))
            ;; rebuild at the phi point for the remaining users
            (position-after-def! p)
            (let ([s (rebuild ty mphis)])
              (LLVMReplaceAllUsesWith p s)
              (LLVMInstructionEraseFromParent p)))))

      ;; ---- phase 2: re-anchor extracts; localize other users -------
      (define (call-between? d u)
        ;; any call in (d, u) within one block?
        (let loop ([i (LLVMGetNextInstruction d)])
          (cond
            [(or (base:null-ptr? i) (eqv? i u)) #f]
            [(= (LLVMGetInstructionOpcode i) op-call) #t]
            [else (loop (LLVMGetNextInstruction i))])))

      (define (safe-in-place? d u)
        (and (instruction? d)
             (eqv? (LLVMGetInstructionParent d)
                   (LLVMGetInstructionParent u))
             (not (call-between? d u))))

      (define (localize-user! d ty u)
        (cond
          [(= (LLVMGetInstructionOpcode u) op-extractvalue)
           (unless (safe-in-place? d u)
             (let ([e (member-of d (extract-index u))])
               (LLVMReplaceAllUsesWith u e)
               (LLVMInstructionEraseFromParent u)))]
          [(= (LLVMGetInstructionOpcode u) op-phi)
           (error "struct phi survived phase 1" (value->text u))]
          [else                            ; ret, insertvalue, ...
           (unless (safe-in-place? d u)
             (let ([ms (members-of d ty)])
               (LLVMPositionBuilderBefore bld u)
               (let ([s (rebuild ty ms)])
                 (let ([nops (LLVMGetNumOperands u)])
                   (do ([i 0 (+ i 1)]) ((= i nops))
                     (when (eqv? (LLVMGetOperand u i) d)
                       (LLVMSetOperand u i s)))))))]))

      (define (collect-struct-defs f)
        (let floop ([bb (LLVMGetFirstBasicBlock f)] [acc '()])
          (if (base:null-ptr? bb)
              (reverse acc)
              (floop (LLVMGetNextBasicBlock bb)
                     (let iloop ([i (LLVMGetFirstInstruction bb)]
                                 [acc acc])
                       (if (base:null-ptr? i)
                           acc
                           (iloop (LLVMGetNextInstruction i)
                                  (if (gc-struct-type? (LLVMTypeOf i))
                                      (cons i acc)
                                      acc))))))))

      (let floop ([f (LLVMGetFirstFunction (ir:module-live-ptr m))])
        (unless (base:null-ptr? f)
          (unless (base:null-ptr? (LLVMGetFirstBasicBlock f))
            (let phis ()
              (let ([ps (collect-struct-phis f)])
                (unless (null? ps)
                  (for-each split-phi! ps)
                  (phis))))
            (for-each
              (lambda (d)
                (for-each (lambda (u)
                            (localize-user! d (LLVMTypeOf d) u))
                          (users d)))
              (collect-struct-defs f)))
          (floop (LLVMGetNextFunction f))))
      (LLVMDisposeBuilder bld))))
