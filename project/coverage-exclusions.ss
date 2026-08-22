;;; Coverage exclusions ledger (see project/coverage-plan.md).
;;; Every oracle entry that (llscheme ll) does not implement MUST be listed
;;; here with a reason; tests/test-coverage.ss enforces that
;;; observed + excluded = oracle, with no overlap and no stale entries.
;;; Format: (axis enum-entry-name "reason")
(
 ;; -- permanent --
 (opcode LLVMUserOp1 "internal to LLVM passes; never valid in IR")
 (opcode LLVMUserOp2 "internal to LLVM passes; never valid in IR")
 (ordering LLVMAtomicOrderingNotAtomic
           "the absence of an ordering, not a writable one")
 ;; -- obsolete linkage enum entries: not expressible in textual IR --
 (linkage LLVMLinkOnceODRAutoHideLinkage "marked obsolete in Core.h")
 (linkage LLVMDLLImportLinkage "marked obsolete in Core.h")
 (linkage LLVMDLLExportLinkage "marked obsolete in Core.h")
 (linkage LLVMGhostLinkage "marked obsolete in Core.h")
 (linkage LLVMLinkerPrivateLinkage "obsolete; lowered away since LLVM 3")
 (linkage LLVMLinkerPrivateWeakLinkage "obsolete; lowered away since LLVM 3")
)
