#!chezscheme
;;; (abi ta6le) -- threaded Chez variant of a6le: the kernel ABI is
;;; identical (threading is a Chez runtime property, not a machine
;;; one), so this is a re-export.
(library (abi ta6le)
  (export arch os error-convention sys sysno const trap-insns
          sys-fn-items errcheck)
  (import (abi a6le)))
