;;; Inspect one corpus round trip. Artifacts stay under tests/tmp/corpus-case/.
[import
 (chezscheme)
 (prefix (llvm ir) ir:)
 (prefix (sll) sll:)
 (prefix (sll render) render:)
 (prefix (tests normalize) n:)]
(define path (cadr (command-line)))
(define ctx (ir:make-context))
(define rctx (ir:make-context))
(define m (ir:parse-ir ctx path (call-with-input-file path get-string-all)))
(n:normalize-module! m)
(define prog (sll:unbuild m 'ignore-named-metadata 'tolerate-builder-folds))
(define m2 (sll:build rctx "rebuilt" prog))
(n:normalize-module! m2)
[for-each
 (lambda (p) (unless (file-exists? p) (mkdir p)))
 '("tests/tmp" "tests/tmp/corpus-case")]
[for-each
 [lambda
  (name text)
  [call-with-output-file
   (string-append "tests/tmp/corpus-case/" name)
   (lambda (p) (display text p))
   'replace]]
 '("before.ll" "after.ll" "render.ll")
 [list
  (n:comparable-ir (ir:module->string m))
  (n:comparable-ir (ir:module->string m2))
  (render:sll->ll prog)]]
[system
 "diff -u tests/tmp/corpus-case/before.ll tests/tmp/corpus-case/after.ll"]
[guard
 (e (else (display-condition e) (newline) (exit 1)))
 (ir:parse-ir (ir:make-context) "render" (render:sll->ll prog))]
