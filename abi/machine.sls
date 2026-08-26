#!chezscheme
;;; (abi machine) -- the compiling host's kernel ABI, selected by
;;; Chez's (machine-type). Import this unless you are deliberately
;;; cross-targeting, in which case import the specific module.
(library (abi machine)
  (export arch os error-convention sys sysno const trap-insns)
  (import (chezscheme))
  (define-values (arch os error-convention sys sysno const trap-insns)
    (case (machine-type)
      [(a6le) (let ()
                (import (abi a6le))
                (values arch os error-convention sys sysno const trap-insns))]
      [(ta6le) (let ()
                 (import (abi ta6le))
                 (values arch os error-convention sys sysno const trap-insns))]
      [(a6fb) (let ()
                (import (abi a6fb))
                (values arch os error-convention sys sysno const trap-insns))]
      [(ta6fb) (let ()
                 (import (abi ta6fb))
                 (values arch os error-convention sys sysno const trap-insns))]
      [(arm64le) (let ()
                   (import (abi arm64le))
                   (values arch os error-convention sys sysno const trap-insns))]
      [(tarm64le) (let ()
                    (import (abi tarm64le))
                    (values arch os error-convention sys sysno const trap-insns))]
      [else (assertion-violation 'abi "no kernel ABI for this machine type"
                                 (machine-type))])))
