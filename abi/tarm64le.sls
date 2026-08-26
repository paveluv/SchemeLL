#!chezscheme
;;; (abi tarm64le) -- threaded Chez variant of arm64le: the kernel ABI is
;;; identical (threading is a Chez runtime property, not a machine
;;; one), so this is a re-export.
(library (abi tarm64le)
  (export arch os error-convention sys sysno const trap-insns)
  (import (abi arm64le)))
