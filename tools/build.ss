;;; build.ss -- compile every library to Chez object files (make build).
;;;
;;;   scheme --compile-imported-libraries --libdirs . --script tools/build.ss \
;;;       [--llvm N | --llvm-prefix DIR] [--chez PATH]
;;;
;;; A --script entry point, like tests/run.ss, so the hosted flags reach
;;; host/bootstrap.ss: a bare `scheme -q` reads anything after its own options
;;; as files to load. Run from the repository root, as make does.
(load "host/bootstrap.ss")
[import
 (prefix (sll) sll:)
 (prefix (sll render) render:)
 (prefix (sll asm) asm:)
 (prefix (llvm target) target:)
 (prefix (tests normalize) n:)]
