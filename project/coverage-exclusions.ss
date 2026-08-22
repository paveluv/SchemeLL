;;; Coverage exclusions ledger (see project/coverage-plan.md).
;;; Every oracle entry that (llscheme ll) does not implement MUST be listed
;;; here with a reason; tests/test-coverage.ss enforces that
;;; observed + excluded = oracle, with no overlap and no stale entries.
;;; Format: (axis enum-entry-name "reason")
(
 ;; -- planned: coverage-plan step 5 (exception handling, last) --
 (opcode LLVMInvoke "exception handling deferred")
 (opcode LLVMCallBr "exception handling / asm goto deferred")
 (opcode LLVMResume "exception handling deferred")
 (opcode LLVMLandingPad "exception handling deferred")
 (opcode LLVMCleanupRet "exception handling deferred")
 (opcode LLVMCatchRet "exception handling deferred")
 (opcode LLVMCatchPad "exception handling deferred")
 (opcode LLVMCleanupPad "exception handling deferred")
 (opcode LLVMCatchSwitch "exception handling deferred")
 ;; -- permanent --
 (opcode LLVMUserOp1 "internal to LLVM passes; never valid in IR")
 (opcode LLVMUserOp2 "internal to LLVM passes; never valid in IR")
 (ordering LLVMAtomicOrderingNotAtomic
           "the absence of an ordering, not a writable one")
)
