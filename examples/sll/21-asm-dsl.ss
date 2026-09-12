;;; Optional legacy environment input belongs to this hosted example.
(load "host/bootstrap.ss")

;;; EXPERIMENTAL (sll asm): structured inline asm. Operands get NAMES; the
;;; library computes LangRef's $N numbering and builds the constraint string --
;;; the two classic hand-written asm bug classes gone. Target-specific
;;; constraint letters (r, m, {rax}, Upl, ...) pass through uninterpreted;
;;; codegen diagnostics remain the arbiter.
[import
 (chezscheme)
 (prefix (sll) sll:)
 (prefix (sll asm) asm:)
 (prefix (llvm target) target:)]

;; Inline asm is written for the host's backend: rdtsc on x86 leaves the
;; counter's halves in two fixed registers; AArch64 reads its virtual counter
;; into any register.
(define host (target:native-target-name))

[define
 counter
 [cond
  [(string=? host "X86")
   [asm:expr
    '[(out lo (reg rax))
      (out hi (reg rdx))]
    "rdtsc"
    'sideeffect]]
  [(string=? host "AArch64")
   (asm:expr '((out ticks r)) '("mrs " ticks ", cntvct_el0") 'sideeffect)]
  (else (error 'asm-dsl "no cycle counter asm for this host" host))]]

(printf "host backend: ~a~%generated form:~%  ~s~%~%" host counter)

[define
 cycle-lo
 [sll:procedure
  [if
   (string=? host "X86")
   `[[define
      i64
      (@cycle_lo)
      [label
       %entry
       (= %pair (call (struct i64 i64) (,counter)))
       (= %lo (extractvalue ((struct i64 i64) %pair) 0))
       (ret i64 %lo)]]]
   `[[define
      i64
      (@cycle_lo)
      (label %entry (= %lo (call i64 (,counter))) (ret i64 %lo))]]]
  "cycle_lo"]]

(printf "cycle counter low word: ~a~%" (cycle-lo))
(printf "cycle counter low word: ~a (later)~%" (cycle-lo))
