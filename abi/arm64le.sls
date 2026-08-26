#!chezscheme
;;; (abi arm64le) -- ARM64 Linux kernel ABI, raw. `svc #0`, number in
;;; x8, args in x0-x5, result in x0; -errno errors like all Linux.
(library (abi arm64le)
  (export arch os error-convention sys sysno const trap-insns)
  (import (chezscheme) (prefix (abi common) common:))

  (define arch 'arm64)
  (define os 'linux)
  (define error-convention 'neg-errno)

  (define sys
    (common:make-sys "svc #0" 'x8 'x0 '(x0 x1 x2 x3 x4 x5) '()))

  (define syscall-numbers
    '((close . 57) (read . 63) (write . 64)
      (exit . 93) (exit_group . 94) (kill . 129)
      (getpid . 172) (munmap . 215) (mmap . 222) (mprotect . 226)))

  (define (sysno name) (common:lookup 'sysno syscall-numbers name))

  (define constants   ; identical to x86-64 Linux for these
    '((prot-none . 0) (prot-read . 1) (prot-write . 2) (prot-exec . 4)
      (map-private . 2) (map-fixed . #x10) (map-anonymous . #x20)))

  (define (const name) (common:lookup 'const constants name))

  (define trap-insns (common:make-trap "brk #0")))
