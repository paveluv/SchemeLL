;;; Coverage exclusions ledger (see project/coverage-plan.md).
;;; Every oracle entry that (llscheme ll) does not implement MUST be listed
;;; here with a reason; tests/test-coverage.ss enforces that
;;; observed + excluded = oracle, with no overlap and no stale entries.
;;; Format: (axis enum-entry-name "reason")
(
 ;; -- planned: coverage-plan step 3 (easy instructions) --
 (opcode LLVMSwitch "not yet implemented: switch")
 (opcode LLVMIndirectBr "not yet implemented: indirectbr")
 (opcode LLVMUnreachable "not yet implemented: unreachable")
 (opcode LLVMFreeze "not yet implemented: freeze")
 (opcode LLVMVAArg "not yet implemented: va_arg")
 (opcode LLVMAddrSpaceCast "not yet implemented: addrspacecast")
 ;; -- planned: step 3 (vectors) --
 (opcode LLVMExtractElement "vector ops: type grammar lacks vectors")
 (opcode LLVMInsertElement "vector ops: type grammar lacks vectors")
 (opcode LLVMShuffleVector "vector ops: type grammar lacks vectors")
 ;; -- planned: step 3/4 (aggregates) --
 (opcode LLVMExtractValue "aggregate ops: type grammar lacks arrays/structs")
 (opcode LLVMInsertValue "aggregate ops: type grammar lacks arrays/structs")
 ;; -- planned: step 3 (atomics) --
 (opcode LLVMFence "atomics not yet implemented")
 (opcode LLVMAtomicCmpXchg "atomics not yet implemented")
 (opcode LLVMAtomicRMW "atomics not yet implemented")
 ;; -- planned: step 5 (exception handling, last) --
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
)
