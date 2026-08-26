#!chezscheme
;;; (abi a6fb) -- FreeBSD amd64 kernel ABI, raw. Same register
;;; convention as Linux x86-64 (syscall; rax; rdi rsi rdx r10 r8 r9;
;;; rcx/r11 clobbered) but DIFFERENT numbers and a DIFFERENT error
;;; convention: errors set the CARRY FLAG with a positive errno in
;;; rax. The raw splice does not capture the flag yet (TODO: an
;;; ={@ccc} flag-output operand); until then callers use the
;;; documented heuristic -- for address-returning calls like mmap, a
;;; result < 4096 is an error (page zero is never mapped and errno
;;; values are small). User-verified on FreeBSD, as usual.
(library (abi a6fb)
  (export arch os error-convention sys sysno const trap-insns)
  (import (chezscheme) (prefix (abi common) common:))

  (define arch 'x86-64)
  (define os 'freebsd)
  (define error-convention 'carry-flag)

  (define sys
    (common:make-sys "syscall" 'rax 'rax
                     '(rdi rsi rdx r10 r8 r9) '(rcx r11)))

  (define syscall-numbers   ; syscalls.master numbering
    '((exit . 1) (read . 3) (write . 4) (close . 6)
      (getpid . 20) (kill . 37)
      (munmap . 73) (mprotect . 74)
      (mmap . 477)))

  (define (sysno name) (common:lookup 'sysno syscall-numbers name))

  (define constants
    '((prot-none . 0) (prot-read . 1) (prot-write . 2) (prot-exec . 4)
      (map-private . 2) (map-fixed . #x10) (map-anonymous . #x1000)))

  (define (const name) (common:lookup 'const constants name))

  (define trap-insns (common:make-trap "ud2")))
