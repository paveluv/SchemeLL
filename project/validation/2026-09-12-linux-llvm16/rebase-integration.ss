#!chezscheme
(load "host/bootstrap.ss")
[import
 (chezscheme)
 (prefix (llvm ir) ir:)
 (prefix (llvm config) config:)
 (prefix (sll) sll:)
 (prefix (sll render) render:)
 (prefix (tests normalize) n:)
 (prefix (tests harness) t:)]

[define
 (contains? text part)
 [let
  loop
  ((i 0))
  [and
   (<= (+ i (string-length part)) (string-length text))
   [or
    (string=? part (substring text i (+ i (string-length part))))
    (loop (+ i 1))]]]]

[define
 source
 "%Cell = type { i32, %Cell* }
@data = global [2 x i32] [i32 7, i32 9]
define i32 @bump(i32 addrspace(1)* %p, i64 %i) {
entry:
  %q = getelementptr i32, i32 addrspace(1)* %p, i64 %i
  %v = load i32, i32 addrspace(1)* %q, align 4
  %n = add i32 %v, 1
  store i32 %n, i32 addrspace(1)* %q, align 4
  ret i32 %n
}
define i32* @indirect(i32* (i32*)* %f, i32** %pp) {
entry:
  %p = load i32*, i32** %pp, align 8
  %r = call i32* %f(i32* %p)
  ret i32* %r
}
define %Cell* @next(%Cell* %p) {
entry:
  %q = getelementptr %Cell, %Cell* %p, i32 0, i32 1
  %r = load %Cell*, %Cell** %q, align 8
  ret %Cell* %r
}
"]

[define
 (context)
 [let
  ((ctx (ir:make-context)))
  [when
   (config:capability? 'typed-pointers)
   (ir:context-use-typed-pointers! ctx)]
  ctx]]

(printf "Rebase integration on LLVM ~s\n" (config:version))
[let*
 [(ctx (context))
  (ctx2 (context))
  (ctx3 (context))
  (m (ir:parse-ir ctx "typed-integration" source))
  (program (sll:unbuild m))
  (rebuilt (sll:build ctx2 "rebuilt" program))
  [rendered
   [ir:parse-ir
    ctx3
    "rendered"
    [parameterize
     ((render:typed-pointers? (config:capability? 'typed-pointers)))
     (render:sll->ll program)]]]]
 (for-each ir:verify-module (list m rebuilt rendered))
 [t:check
  "typed loads, stores, GEPs, indirect calls and recursive structs rebuild exactly"
  [string=?
   (n:comparable-ir (ir:module->string m))
   (n:comparable-ir (ir:module->string rebuilt))]]
 [t:check
  "typed-pointer renderer preserves canonical IR exactly"
  [string=?
   (n:comparable-ir (ir:module->string m))
   (n:comparable-ir (ir:module->string rendered))]]
 [ir:add-named-metadata!
  rebuilt
  "integration.functions"
  [ir:md-node
   ctx2
   [list
    (ir:md-string ctx2 "bump")
    (ir:value-as-metadata (ir:named-function rebuilt "bump"))]]]
 [for-each
  [lambda
   (entry)
   [ir:add-named-metadata!
    rebuilt
    "llvm.module.flags"
    [ir:md-node
     ctx2
     [list
      (ir:value-as-metadata (ir:const-int (ir:int32-type ctx2) (car entry)))
      (ir:md-string ctx2 (cadr entry))
      [ir:value-as-metadata
       (ir:const-int (ir:int32-type ctx2) (caddr entry))]]]]]
  '[(7 "integration.max" 4)
    (8 "integration.min" 2)]]
 (ir:verify-module rebuilt)
 [let*
  [(dir "tests/tmp/rebase-integration")
   (bc (string-append dir "/module.bc"))
   (ll (string-append dir "/module.ll"))]
  (unless (file-exists? "tests/tmp") (mkdir "tests/tmp"))
  (unless (file-exists? dir) (mkdir dir))
  [call-with-port
   (open-file-output-port bc (file-options no-fail))
   (lambda (out) (put-bytevector out (ir:module->bitcode rebuilt)))]
  [t:check
   "the matching llvm-dis reads rebuilt bitcode"
   [zero?
    [system
     [format
      "/usr/lib/llvm-~a/bin/llvm-dis ~a ~a -o ~a"
      config:major-version
      (if (config:capability? 'typed-pointers) "-opaque-pointers=0" "")
      bc
      ll]]]]
  [let
   ((text (call-with-input-file ll get-string-all)))
   [t:check
    "named function metadata survives bitcode with the selected pointer model"
    [and
     (contains? text "!integration.functions = !{")
     [contains?
      text
      [if
       (config:capability? 'typed-pointers)
       "!\"bump\", i32 (i32 addrspace(1)*, i64)* @bump"
       "!\"bump\", ptr @bump"]]]]
   [t:check
    "Max and Min module flags survive bitcode"
    [and
     (contains? text "!{i32 7, !\"integration.max\", i32 4}")
     (contains? text "!{i32 8, !\"integration.min\", i32 2}")]]]]
 (for-each ir:module-dispose! (list m rebuilt rendered))
 (for-each ir:context-dispose! (list ctx ctx2 ctx3))]
(t:summary-and-exit)
