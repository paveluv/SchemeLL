#!chezscheme
;;; (abi a6fb) -- FreeBSD amd64 kernel ABI, raw. Same register
;;; convention as Linux x86-64 (syscall; rax; rdi rsi rdx r10 r8 r9;
;;; rcx/r11 clobbered) but DIFFERENT numbers and a DIFFERENT error
;;; convention: errors set the CARRY FLAG with a positive errno in
;;; rax. The raw `sys` splice returns rax alone (lossy for
;;; small-integer successes); the @sys_* function layer captures CF
;;; via ={@ccc} and normalizes to -errno, so portable callers use
;;; THAT. CF semantics after a real syscall are user-verified on
;;; FreeBSD (the ={@ccc} plumbing itself is pinned kernel-free by
;;; the stc/clc tests).
(library (abi a6fb)
  (export arch os error-convention sys sysno const trap-insns
          sys-fn-items errcheck)
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

  (define trap-insns (common:make-trap "ud2"))

  ;; the @sys_* function layer: carry-flag capture (={@ccc}) +
  ;; branchless select, normalized to -errno like every OS
  (define sys-fn-items
    (common:make-sys-fns "syscall" 'rax 'rax
                         '(rdi rsi rdx r10 r8 r9) '(rcx r11)
                         'carry-flag sysno common:default-syscall-fns))

  (define errcheck common:errcheck))
