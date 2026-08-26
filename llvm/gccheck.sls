#!chezscheme
;;; (llvm gccheck) -- the bit-leak checker: the compile-time gate for
;;; the tagged-pointer/statepoint discipline (its rationale and the
;;; probed miscompile it prevents: MeikScheme project/object-repr.md
;;; "Enforcement"). The rule: every `ptrtoint` whose source is a
;;; pointer in the GC address space may feed ONLY `and` instructions
;;; whose constant mask is a subset of the tag mask -- tag bits are
;;; relocation-invariant, full addresses are not, and CSE/GVN may
;;; legally merge frontend ptrtoints across safepoints (probed), so
;;; anything wider than the tag bits can carry stale address bits
;;; past a relocation.
;;;
;;; Placement: run on FRONTEND IR, BEFORE optimization (found
;;; empirically: instcombine rewrites conforming mask arithmetic --
;;; tag+tag becomes shl -- into shapes this syntactic rule cannot
;;; recognize, so post-O2 checking would need a demanded-bits
;;; analysis). Pre-O2 checking is sound: conforming code's behavior
;;; depends only on relocation-invariant bits, and the optimizer's
;;; own contract -- semantic preservation -- carries that property
;;; through every transform, mergers included. A violation is a
;;; raised error naming the function and printing the offending
;;; instructions -- a compile failure, never a wrong answer.
(library (llvm gccheck)
  (export assert-no-pointer-leaks!)
  (import (except (chezscheme) error)
          (prefix (llvm raw) LLVM)
          (prefix (llvm base) base:)
          (prefix (llvm ir) ir:))

  (define (error msg . irritants)
    (apply base:error 'gccheck:assert-no-pointer-leaks! msg irritants))

  ;; LLVMOpcode values, cross-checked by the coverage suite's header
  ;; oracle (tests/test-coverage.ss pins the full table)
  (define op-and 23)
  (define op-ptrtoint 39)

  (define (value->text v)
    (base:cstring->string/dispose (LLVMPrintValueToString v)))

  (define (const-int-value v)
    (and (not (base:null-ptr? (LLVMIsAConstantInt v)))
         (LLVMConstIntGetZExtValue v)))

  ;; is USER an `and` of the cast with a constant mask within MASK?
  (define (conforming-user? cast user mask)
    (and (= (LLVMGetInstructionOpcode user) op-and)
         (let* ([a (LLVMGetOperand user 0)]
                [b (LLVMGetOperand user 1)]
                [c (const-int-value (if (eqv? a cast) b a))])
           (and c (zero? (bitwise-and c (bitwise-not mask)))))))

  (define (check-cast! fname cast addrspace mask)
    (let loop ([u (LLVMGetFirstUse cast)])
      (unless (base:null-ptr? u)
        (let ([user (LLVMGetUser u)])
          (unless (conforming-user? cast user mask)
            (error
              (format
                "address bits of an addrspace(~a) pointer escape past a tag mask (~a); only (and x mask<=~a) may consume such a ptrtoint -- full addresses are not relocation-stable"
                addrspace fname mask)
              (value->text cast)
              (value->text user))))
        (loop (LLVMGetNextUse u)))))

  ;; Walk MODULE; raise on the first violation. addrspace: the GC
  ;; pointer space (Meik: 1). mask: the tag mask (Meik: 7).
  (define (assert-no-pointer-leaks! m addrspace mask)
    (let floop ([f (LLVMGetFirstFunction (ir:module-live-ptr m))])
      (unless (base:null-ptr? f)
        (let ([fname (ir:value-name f)])
          (let bloop ([b (LLVMGetFirstBasicBlock f)])
            (unless (base:null-ptr? b)
              (let iloop ([i (LLVMGetFirstInstruction b)])
                (unless (base:null-ptr? i)
                  (when (and (= (LLVMGetInstructionOpcode i) op-ptrtoint)
                             (= (LLVMGetPointerAddressSpace
                                  (LLVMTypeOf (LLVMGetOperand i 0)))
                                addrspace))
                    (check-cast! fname i addrspace mask))
                  (iloop (LLVMGetNextInstruction i))))
              (bloop (LLVMGetNextBasicBlock b)))))
        (floop (LLVMGetNextFunction f))))))
