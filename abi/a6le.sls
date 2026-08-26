#!chezscheme
;;; (abi a6le) -- x86-64 Linux kernel ABI, raw. Hand-written for the
;;; targets we care about; eventually generated from kernel headers.
;;; Convention: `syscall` insn, number in rax, args in rdi rsi rdx
;;; r10 r8 r9 (NOT rcx -- the syscall insn clobbers rcx/r11 for the
;;; return address and rflags), result in rax. Errors return -errno
;;; in rax: error iff (unsigned)ret > -4096.
(library (abi a6le)
  (export arch os error-convention sys sysno const trap-insns)
  (import (chezscheme) (prefix (abi common) common:))

  (define arch 'x86-64)
  (define os 'linux)
  (define error-convention 'neg-errno)

  (define sys
    (common:make-sys "syscall" 'rax 'rax
                     '(rdi rsi rdx r10 r8 r9) '(rcx r11)))

  (define syscall-numbers
    '((read . 0) (write . 1) (close . 3)
      (mmap . 9) (mprotect . 10) (munmap . 11)
      (getpid . 39) (exit . 60) (kill . 62)
      (exit_group . 231)))

  (define (sysno name) (common:lookup 'sysno syscall-numbers name))

  (define constants
    '((prot-none . 0) (prot-read . 1) (prot-write . 2) (prot-exec . 4)
      (map-private . 2) (map-fixed . #x10) (map-anonymous . #x20)))

  (define (const name) (common:lookup 'const constants name))

  (define trap-insns (common:make-trap "ud2")))
