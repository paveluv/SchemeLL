;;; EXPERIMENTAL (sll asm): structured inline asm. Operands get NAMES; the
;;; library computes LangRef's $N numbering and builds the constraint string --
;;; the two classic hand-written asm bug classes gone. Target-specific
;;; constraint letters (r, m, {rax}, Upl, ...) pass through uninterpreted;
;;; codegen diagnostics remain the arbiter.
(import (chezscheme) (prefix (sll) sll:) (prefix (sll asm) asm:))

[define
 rdtsc
 [asm:expr
  '[(out lo (reg rax))
    (out hi (reg rdx))]
  "rdtsc"
  'sideeffect]]

(printf "generated form:~%  ~s~%~%" rdtsc)

[define
 cycle-lo
 [sll:procedure
  `[[define
     i64
     (@cycle_lo)
     [label
      %entry
      (= %pair (call (struct i64 i64) (,rdtsc)))
      (= %lo (extractvalue ((struct i64 i64) %pair) 0))
      (ret i64 %lo)]]]
  "cycle_lo"]]

(printf "rdtsc low word: ~a~%" (cycle-lo))

(printf "rdtsc low word: ~a (later)~%" (cycle-lo))
