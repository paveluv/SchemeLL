;;; (sll asm) -- the structured inline-asm generator.
(import (chezscheme)
        (prefix (tests harness) t:)
        (prefix (sll asm) asm:)
        (prefix (sll) sll:))

(t:section "asm: constraint generation")

(t:check "outputs, tied input, clobber"
         (equal? (asm:expr '((out sum r)
                             (in a (tied sum))
                             (in b r)
                             (clobber cc))
                           '("add " b ", " sum)
                           'sideeffect)
                 '(asm "add $2, $0" "=r,0,r,~{cc}" sideeffect)))

(t:check "explicit registers reproduce the hand-written hello string"
         (equal? (asm:expr '((out ret (reg rax))
                             (in nr (reg rax)) (in fd (reg rdi))
                             (in buf (reg rsi)) (in len (reg rdx))
                             (clobber rcx r11 memory))
                           "syscall"
                           'sideeffect)
                 '(asm "syscall"
                       "={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"
                       sideeffect)))

(t:check "inout lowers to output + hidden tied input"
         (equal? (asm:expr '((inout x r)) '("incq " x) 'sideeffect)
                 '(asm "incq $0" "=r,0" sideeffect)))

(t:check "early clobber, alternatives, modifiers, $ escaping"
         (equal? (asm:expr '((out! d (r m))
                             (in s r))
                           '("mov " (: s w) ", " d "  # costs $$5"))
                 '(asm "mov ${1:w}, $0  # costs $$$$5" "=&rm,r")))

(t:check "item order does not matter (numbering is canonical)"
         (equal? (asm:expr '((in a (tied b)) (out b r)) "nop")
                 '(asm "nop" "=r,0")))

(t:check-exn "tied must reference an output"
             (asm:expr '((in a (tied nothing)) (out b r)) "nop"))
(t:check-exn "duplicate names rejected"
             (asm:expr '((out x r) (in x r)) "nop"))
(t:check-exn "unknown template operand rejected"
             (asm:expr '((out x r)) '("mov " y)))
(t:check-exn "unknown flag rejected"
             (asm:expr '((out x r)) "nop" 'sideffect))

(t:section "asm: end to end")

(t:check "generated asm JITs and runs"
         (= 42 ((sll:procedure
                  `((define i64 (@f (i64 %a) (i64 %b))
                      (label %entry
                        (= %r (call i64 (,(asm:expr
                                            '((out sum r)
                                              (in a (tied sum))
                                              (in b r))
                                            '("add " b ", " sum)
                                            'sideeffect)
                                         (i64 %a) (i64 %b))))
                        (ret i64 %r))))
                  "f")
                40 2)))
