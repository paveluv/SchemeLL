;;; hello-portable-asm-dsl.ss -- hello-portable.ss rebuilt on (sll asm).
;;;
;;; In hello-portable.ss the per-kernel-ABI difference is two
;;; hand-written asm forms per target: instruction, register names,
;;; constraint punctuation, and syscall numbers all live inside opaque
;;; strings. With the structured DSL the difference shrinks to a TABLE
;;; -- registers as symbols, numbers as numbers -- and one generator
;;; turns table rows into correct-by-construction asm forms: the
;;; constraint strings and operand numbering are computed, never
;;; spelled.
;;;
;;; Run with: scheme --libdirs . --script examples/aot/hello-portable-asm-dsl.ss
(import (chezscheme)
        (prefix (sll) sll:)
        (prefix (sll asm) asm:)
        (prefix (llvm ir) ir:)
        (prefix (llvm target) target:))

;; everything that differs between kernel ABIs, as plain data
(define abis
  '((linux-x86_64
      (backend "X86") (triple "x86_64-unknown-linux-gnu")
      (instruction "syscall")
      (nr-reg rax) (ret-reg rax) (arg-regs rdi rsi rdx)
      (clobbers rcx r11)
      (sys-write 1) (sys-exit 231))
    (linux-aarch64
      (backend "AArch64") (triple "aarch64-unknown-linux-gnu")
      (instruction "svc #0")
      (nr-reg x8) (ret-reg x0) (arg-regs x0 x1 x2)
      (clobbers)
      (sys-write 64) (sys-exit 94))))

(define (abi-ref abi key)
  (cdr (assq key (cdr (assq abi abis)))))

;; one generator covers every ABI: a syscall asm callee taking the
;; number plus NARGS arguments
(define (syscall-asm abi nargs)
  (apply asm:expr
         `((out ret (reg ,(car (abi-ref abi 'ret-reg))))
           (in nr (reg ,(car (abi-ref abi 'nr-reg))))
           ,@(let loop ([regs (abi-ref abi 'arg-regs)] [i 0])
               (if (or (null? regs) (= i nargs))
                   '()
                   (cons `(in ,(string->symbol
                                 (string-append "arg" (number->string i)))
                              (reg ,(car regs)))
                         (loop (cdr regs) (+ i 1)))))
           (clobber ,@(abi-ref abi 'clobbers) memory))
         (car (abi-ref abi 'instruction))
         '(sideeffect)))

;; the portable 99%, identical for every target
(define (hello-prog abi)
  `((define void (@_start)
      (label %entry
        (= %buf (alloca (array 24 i8) (align 8)))
        (store (i64 5989836361474794824) (ptr %buf) (align 8))   ; "Hello, S"
        (= %p8 (getelementptr i8 (ptr %buf) (i64 8)))
        (store (i64 2399376699992402019) (ptr %p8) (align 8))    ; "chemeLL!"
        (= %p16 (getelementptr i8 (ptr %buf) (i64 16)))
        (store (i8 10) (ptr %p16))
        (call i64 (,(syscall-asm abi 3)
                   (i64 ,(car (abi-ref abi 'sys-write)))
                   (i64 1) (ptr %buf) (i64 17)))
        (call i64 (,(syscall-asm abi 0)
                   (i64 ,(car (abi-ref abi 'sys-exit)))))
        (unreachable)))))

(for-each
  (lambda (entry)
    (let* ([abi (car entry)]
           [triple (car (abi-ref abi 'triple))]
           [out (string-append "/tmp/hello-dsl-"
                               (symbol->string abi) ".o")])
      (printf "~%=== ~a: the generated write syscall ===~%  ~s~%"
              abi (syscall-asm abi 3))
      (if (target:initialize-target! (car (abi-ref abi 'backend)))
          (let* ([ctx (ir:make-context)]
                 [m (sll:build ctx (symbol->string abi) (hello-prog abi))]
                 [tm (target:make-machine triple "generic" "" 'default)])
            (ir:verify-module m)
            (ir:set-module-target-triple! m triple)
            (target:emit-object-file tm m out)
            (printf "  -> ~a~%" out))
          (printf "  (no ~a backend in this libLLVM; skipped)~%"
                  (car (abi-ref abi 'backend))))))
  abis)

(printf "~%The ABI table is symbols and numbers; the constraint strings~%")
(printf "above were computed by (sll asm), never written by hand.~%")
