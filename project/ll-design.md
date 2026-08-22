# Design proposal: (llscheme ll) — LLVM IR as s-expressions

Status: PROPOSAL, not implemented. First layer of the llscheme DSL tower:
a notation for LLVM IR that is ordinary Scheme data/syntax, sitting directly
on top of (llvm ir).

## Guiding principle: mechanical transliteration

ll is textual LLVM IR with a fixed, reversible set of rewrites — nothing
more. Anyone reading LLVM docs should be able to write ll without learning
a second language, and `clang -S -emit-llvm` output should transliterate
into ll line by line (great for learning and debugging). The rewrites:

1. Drop commas. Wrap each instruction in parens.
2. `%x = <rhs>` becomes `(= %x (<rhs>))`. `%x`, `%same.ok`, `@fact` are
   ordinary Scheme symbols — the sigils survive untouched.
3. Type annotations stay exactly where IR writes them (once per shared-type
   instruction, per-operand where IR is per-operand). Typed operand groups
   get parens: `store i64 %a, ptr %b` keeps two groups.
4. `label %x` targets become `(label %x)`; a block header `x:` becomes the
   instruction `(label %x)`. Note the deliberate deviation: IR spells a block
   name two ways (`x:` at definition, `%x` at reference), ll spells it one
   way. Blocks are function-local values in LLVM's `%` namespace (unnamed
   blocks even share the auto-numbering counter with instruction results),
   and one-name-one-symbol means the interpreter, future nanopass layers
   emitting branches, and plain grep all match labels with simple symbol
   equality. DECIDED 2026-08-21.
5. phi's `[ 0, %entry ]` becomes `[0 %entry]` (Chez reads brackets as parens).
6. Trailing attributes become trailing groups: `, align 8` → `(align 8)`.
   Instruction flags stay in position as bare symbols: `icmp ne`, `add nsw`,
   `getelementptr inbounds` → `(icmp ne ...)`, `(add nsw ...)`, ...

Examples of the rule at work:

| LLVM IR | ll |
|---|---|
| `%sum = add i32 %a, %b` | `(= %sum (add i32 %a %b))` |
| `%ok = icmp ne i32 %goal, 0` | `(= %ok (icmp ne i32 %goal 0))` |
| `store i64 %a, ptr %b, align 8` | `(store (i64 %a) (ptr %b) (align 8))` |
| `%v = load i64, ptr %p` | `(= %v (load i64 (ptr %p)))` |
| `%r = call i64 @fact(i64 %n1)` | `(= %r (call i64 @fact (i64 %n1)))` |
| `br label %loop` | `(br (label %loop))` |
| `br i1 %ok, label %a, label %b` | `(br i1 %ok (label %a) (label %b))` |
| `ret i64 %r` | `(ret i64 %r)` |
| `%i = phi i64 [ 0, %entry ], [ %i1, %loop ]` | `(= %i (phi i64 [0 %entry] [%i1 %loop]))` |

Function definitions follow IR word order (`define <ret> @name(<args>)`):

```scheme
(define i64 (@fact (i64 %n))
  body ...)
(declare i32 (@puts ptr))
```

`define`/`declare` here are ll grammar words inside an ll form, not Scheme's —
see "Macros" below for why that never collides.

## A complete function, side by side

```llvm
define i64 @fact(i64 %n) {          (define i64 (@fact (i64 %n))
entry:
  %isbase = icmp slt i64 %n, 2        (= %isbase (icmp slt i64 %n 2))
  br i1 %isbase, label %b, label %r   (br i1 %isbase (label %b) (label %r))
b:                                    (label %b)
  ret i64 1                           (ret i64 1)
r:                                    (label %r)
  %n1 = sub i64 %n, 1                 (= %n1 (sub i64 %n 1))
  %f = call i64 @fact(i64 %n1)        (= %f (call i64 @fact (i64 %n1)))
  %r1 = mul i64 %n, %f                (= %r1 (mul i64 %n %f))
  ret i64 %r1                         (ret i64 %r1))
}
```

Listed vertically it reads as assembly, per the vision.

## Branching: flat with labels (the proposal)

Between "flat with label instructions" and "nested structure", ll should be
**flat**:

- It preserves the transliteration property and the assembly-like reading.
- LLVM IR *is* a flat CFG. Arbitrary control flow — loops with several
  back-edges, shared join blocks, phis — doesn't fit a tree without
  duplication or special cases. Every structured encoding of a CFG is a
  compiler in disguise.
- Structured control flow (`if`/`while`/`for`, lexical variables) is exactly
  the job of the *next* layer (nanopass), which compiles down to ll. That
  mirrors how real front ends target LLVM, and gives the nanopass layer a
  trivially printable, diffable target language.

Block rules:

- The entry block is implicit and named `%entry`; instructions before the
  first `(label ...)` belong to it.
- `(label %x)` starts block `%x`. Labels may be referenced before they are
  defined (forward branches, phi incoming) — building does a block prepass.
- Every block must end in a terminator; block names and `%` names are unique
  per function (SSA). LLVM's verifier backstops both; ll should raise its
  own, better-located errors where cheap.

## Names, constants, escapes

- `%name` = local SSA value, `@name` = global (function, later global var).
- Bare integer/flonum literals are typed by the instruction's type token
  (`(add i64 %n 1)` → `ConstInt(i64, 1)`); where IR would annotate, ll
  annotates: `(i64 1)`.
- Escape hatch for metaprogramming: inside quasiquoted ll data, `,expr`
  splices a computed fragment — an operand, an instruction, a whole block
  list. A raw (llvm ir) value/type pointer is accepted wherever an operand/
  type may appear.

## Implementation: data core + thin macro (the define-syntax exploration)

Three possible embeddings were considered:

**(a) Data interpreter (the core, build first).** An ll program is a list.
`(ll:build ctx name prog)` walks it against an opcode table and produces an
(llvm ir) module:

- pass 1 per function: create the function, collect `(label %x)` and
  pre-create basic blocks (forward references);
- pass 2: emit instructions via (llvm ir) builders, resolving `%`/`@` names
  through per-function/per-module environments (hashtables);
- phis emit empty and record their incoming pairs; a fixup loop at function
  end calls `ir:phi-add-incoming!` (phi is IR's only forward *value*
  reference).

Adding an instruction = one entry in the opcode table. Programs are plain
lists, so "use the full power of Scheme to generate IR" is quasiquote —
no new metaprogramming machinery. This is also the natural target for the
nanopass layer (nanopass languages are s-expression data).

**(b) A thin shell macro over (a).** `(ll:module "fact" (define ...))` is
essentially `(ll:build ctx "fact" `(...))` with auto-quasiquotation. A few
lines of syntax-rules; gives literal-embedding convenience and keeps ONE
semantics (the interpreter's).

**(c) A compiling macro (possible, deferred).** define-syntax CAN do the
whole job: expand `(= %x (add ...))` into nested `let`s so `%x` becomes a
true lexical variable (unbound-name errors at compile time, free mixing with
surrounding Scheme bindings); a syntax-case prepass collects labels; phi
fixups expand at the innermost point, where every `%` binding is in scope.
Opcode dispatch would still go through the runtime table so the macro stays
small. Costs: needs syntax-case identifier surgery, duplicates (a)'s
semantics, and macro-embedded programs stop being data. Worth revisiting
only if compile-time name checking proves valuable in practice.

**What it should NOT be: a set of top-level per-opcode macros.** Defining
`store`, `add`, `=`, `define` as global Scheme macros would shadow and
collide (`=` and `define` catastrophically so) and buys nothing: opcode
forms only ever occur *inside* an ll shell form, which walks its own body,
so opcodes remain unbound symbols in Scheme — zero namespace pollution.
"ll as define-syntax" therefore means one or two shell macros, not a macro
per instruction.

Recommendation: implement (a) then (b); leave (c) as a documented option.

## Library and API sketch

```scheme
(import (prefix (llscheme ll) ll:))

(define prog
  '((define i64 (@fact (i64 %n))
      ...)))

(define mod (ll:build ctx "fact" prog))   ; → (llvm ir) module record
```

plus a jit convenience (build + add-module! + context handling) so the
README demo becomes ~5 lines. Initial instruction coverage = what (llvm ir)
wraps today: integer/float arithmetic, icmp/fcmp, br/ret, phi, call,
alloca/load/store/gep, casts, select.

## Open questions (for later, none blocking)

- br/ret sugar: allow `(br %loop)` / `(br %ok %a %b)` since those types are
  forced? (Fidelity says keep `(label ...)` and `i1`; both could parse.)
- Anonymous values (`%1`-style auto-naming) — probably "no, name things".
- Module-level items beyond functions: globals, struct type definitions
  (`(type %pair (struct i32 i32))`), attributes — add as needed.
- Verifier-grade error messages (block fell through, name redefined) in ll
  itself vs delegating to ir:verify-module.
