# Design proposal: (llscheme ll) — LLVM IR as s-expressions

Status: first slice IMPLEMENTED in `llscheme/ll.sls` (2026-08-21); this
document is the grammar reference. Instruction flags supported since
2026-08-22 (nsw/nuw/exact/disjoint/nneg/volatile, fast-math flags,
getelementptr inbounds/nusw/nuw) — written in IR position between opcode
and type (for fcmp, before the predicate), validated per opcode.
Coverage step 3 (2026-08-22) added: switch, indirectbr (+ blockaddress
constants), unreachable, freeze, va_arg, addrspacecast; vectors
(insert/extract-element, shufflevector with a `(mask i ...)` group);
aggregates (insert/extractvalue with bare integer indices); full atomics
(fence, atomicrmw with all 17 ops, cmpxchg with weak, atomic load/store
with ordering after the operands); `undef` operands; and type grammar for
`(array N TY)`, `(vector N TY)`, `(struct TY ...)`, and
`(ptr (addrspace N))`. (DECIDED 2026-08-22: named heads for aggregate
types rather than IR-positional `[N x TY]`/`<N x TY>` transliteration —
uniform with `struct`, easier to read, and far easier to pattern-match
in the future nanopass layers.) Step 4 (2026-08-22) added
module-level globals: `(= @name (linkage? global|constant type init?
attr*))` (`@x = private constant i64 42` →
`(= @x (constant private i64 42))`); initializers cover literals,
undef/zeroinitializer/null, @globals/@functions, `(c "bytes")` /
`(cz "bytes")` strings, and per-element-typed aggregates
`((i64 1) (i32 2))`; no initializer = declaration (external/extern_weak
only). Step 5 (2026-08-22) completed the opcode set with exception
handling: invoke (`(= %r (invoke ty (callee args...) (label %ok)
(label %pad)))`), landingpad with cleanup/catch/filter clauses,
resume, the funclet family (catchswitch/catchpad/cleanuppad with a
`none|%pad` parent operand, catchret/cleanupret with a `caller` or
label unwind destination), callbr with a required inline-asm callee
`(asm "template" "constraints" sideeffect? alignstack?)` (asm callees
also work in call), and an optional `(personality ptr @fn)` clause
between a define's signature and its first block. Every LLVMOpcode is
now implemented except UserOp1/2 (permanently excluded — never valid
in IR). Step 5.5 (2026-08-22, pre-corpus blockers): varargs — a
trailing `variadic` marker in define/declare signatures (never spelled
`...`, which is ellipsis in nanopass patterns) and `(fn RET ARG ...
variadic?)` function types in the call/invoke/callbr type slot, as IR
requires for vararg call sites; tail-call markers as leading call
flags (`(call tail ...)` — IR's `tail call` normalized head-first like
global linkage); alloca element counts `(alloca i64 (i64 %n))`; and
non-phi forward references — LLVM's own printer emits blocks in
non-dominance order, so unresolved `%names` in typed positions become
freeze-of-undef placeholders in a scratch block, patched via
ReplaceAllUsesWith and erased at end of function. Not yet supported
(rejected with clear errors): constant expressions (opaque pointers
made the common ones unnecessary; add on demand) and raw value
injection (the reserved `(ptr N)` operand shape).

Corpus-driven additions (2026-08-22, step 6b): function linkage --
`(define internal i64 (@f ...) ...)`, `(declare extern_weak ...)`, the
same optional keyword-operand slot as globals; zero-incoming phis
(legal parse-level IR in dead blocks); and the anonymity rule: all-digit
`%names` (`%0`, `%42`) are positional/anonymous, exactly as in textual
IR where digits are slot numbers, not names -- ll:build binds them in
its environment but leaves the LLVM value unnamed, so LLVM's own
printer reproduces the numbering (a value explicitly named "0" via the
API would print as `%"0"` and is not expressible).

Corpus rounds 2-3 (2026-08-22) added: named struct types --
`(type %name (struct ...))`, `(type %name (packed-struct ...))`,
`(type %name opaque)` module items, referenced as `%name` in type
positions (created before bodies are filled, so mutual recursion works);
`(packed-struct ...)` literal types; `(scalable-vector N TY)`;
`(addrspace N)` groups on globals; integer constants of any width
(>64-bit go through decimal text); aggregate and string constants as
instruction operands; `poison` shuffle-mask lanes.

First layer of the llscheme DSL tower:
a notation for LLVM IR that is ordinary Scheme data/syntax, sitting directly
on top of (llvm ir).

## The design principle (REVIEWED and DECIDED 2026-08-22)

**An ll program is Scheme data that mirrors LLVM's *semantic structure*,
spelled with LLVM's *vocabulary*.**

1. **Prefix-only grammar.** Every composite form is a list whose *head*
   names what it is (`define`, `label`, `=`, an opcode, a type
   constructor, `asm`, `personality`, ...). Grammar words never appear at
   any other position. (Empirically verified: nanopass `define-language`
   productions cannot contain mid-pattern literal symbols — only head
   keywords and meta-variables — so this rule is what keeps ll definable
   as a nanopass language.)
2. **After the head, everything is an operand**: a name (`%x`, `@f`), a
   literal, a **keyword operand** (an enum-like word: `slt`, `seq_cst`,
   `nsw`, `private`, `undef`, `null`, `none`, `caller`), a typed group
   `(type value)`, or a nested form. Each head has a fixed shape (modulo
   natural variadic tails). Keyword operands are data — nanopass models
   them as terminals.
3. **LLVM's vocabulary, LLVM's order.** Opcode names, flag names,
   predicate names, type names, and operand order match textual IR, so
   the LangRef doubles as ll documentation.
4. **Textual fidelity is a tiebreaker, not a goal.** Where IR's concrete
   syntax conflicts with rules 1–2 — infix markers (`to`, `within`,
   `from`, `unwind`), dual spellings (`entry:` vs `%entry`), bracket
   flavors (`[4 x i8]`, `<4 x i32>`) — structure wins and only the
   vocabulary survives.
5. **One name, one symbol.** A thing is spelled identically at definition
   and every use.

The line rules 1–2 draw: *structure words go in head position; semantic
words are operands.* `zext` is structure; `seq_cst` is semantics.

## The transliteration rules

Under the principle, IR converts to ll with a fixed, reversible set of
rewrites, and `clang -S -emit-llvm` output still transliterates line by
line:

1. Drop commas. Wrap each instruction in parens.
2. `%x = <rhs>` becomes `(= %x (<rhs>))`. `%x`, `%same.ok`, `@fact` are
   ordinary Scheme symbols — the sigils survive untouched.
3. Type annotations stay exactly where IR writes them (once per shared-type
   instruction, per-operand where IR is per-operand). Typed operand groups
   get parens: `store i64 %a, ptr %b` keeps two groups.
4. `label %x` branch targets stay `(label %x)`. A block header `x:` opens a
   *block group* `(label %x <insn> ... <terminator>)` that closes before the
   next header — a function body is a list of block groups, and the first
   group is the entry block. Two deliberate deviations from the textual
   form, both DECIDED:
   - Uniform `%` spelling (2026-08-21): IR spells a block name two ways
     (`x:` at definition, `%x` at reference), ll spells it one way. Blocks
     are function-local values in LLVM's `%` namespace (unnamed blocks even
     share the auto-numbering counter with instruction results), and
     one-name-one-symbol means the interpreter, nanopass layers emitting
     branches, and plain grep all match labels with simple symbol equality.
   - Grouped blocks (2026-08-22, replacing the original flat
     label-as-instruction form): groups mirror LLVM's object model
     (functions contain blocks contain instructions), read like asm (labels
     one indent level left of instructions), make blocks the natural splice
     unit for generators, and enable structural checks — instruction
     outside a block, empty block, block not ending in a terminator, and
     no nested blocks are all errors ll raises itself.
5. phi's `[ 0, %entry ]` becomes `[0 %entry]` (Chez reads brackets as parens).
   Note: scheme-format normalizes brackets in quoted data to parens, so in
   committed sources phi pairs appear as `(0 %entry)`; both read the same.
6. Trailing attributes become trailing groups: `, align 8` → `(align 8)`.
   Instruction flags stay in position as bare symbols: `icmp ne`, `add nsw`,
   `getelementptr inbounds` → `(icmp ne ...)`, `(add nsw ...)`, ...
7. Mid-form grammar words are dropped or absorbed (rule 4 of the
   principle; DECIDED 2026-08-22):
   - casts lose `to`: `zext i32 %t to i64` → `(zext i32 %t i64)`;
   - call/invoke/callbr group the callee with its arguments, mirroring
     IR's own `@f(args)`: `call i64 @fact(i64 %n1)` →
     `(call i64 (@fact (i64 %n1)))`; invoke/callbr destinations follow
     as fixed positions with `to`/`unwind` dropped:
     `(invoke i32 (@f (i32 %x)) (label %ok) (label %pad))`,
     `(callbr void ((asm "" "")) (label %fall) ((label %i) ...))`;
   - funclet EH loses `within`/`from`/`unwind`; `to caller` becomes the
     keyword operand `caller`: `(catchswitch none ((label %h)) caller)`,
     `(catchpad %cs (args))`, `(catchret %cp (label %ok))`,
     `(cleanupret %clp caller)`;
   - `ptr addrspace(1)` → `(ptr (addrspace 1))` — the shape `(ptr 1)` is reserved: as an operand group it will mean an inttoptr address constant;
   - global linkage moves after the kind head (the head must name the
     form): `@x = private constant i64 42` →
     `(= @x (constant private i64 42))`.

Examples of the rule at work:

| LLVM IR | ll |
|---|---|
| `%sum = add i32 %a, %b` | `(= %sum (add i32 %a %b))` |
| `%ok = icmp ne i32 %goal, 0` | `(= %ok (icmp ne i32 %goal 0))` |
| `store i64 %a, ptr %b, align 8` | `(store (i64 %a) (ptr %b) (align 8))` |
| `%v = load i64, ptr %p` | `(= %v (load i64 (ptr %p)))` |
| `%r = call i64 @fact(i64 %n1)` | `(= %r (call i64 (@fact (i64 %n1))))` |
| `%t = zext i32 %x to i64` | `(= %t (zext i32 %x i64))` |
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
entry:                                (label %entry
  %isbase = icmp slt i64 %n, 2          (= %isbase (icmp slt i64 %n 2))
  br i1 %isbase, label %b, label %r     (br i1 %isbase (label %b) (label %r)))
b:                                    (label %b
  ret i64 1                             (ret i64 1))
r:                                    (label %r
  %n1 = sub i64 %n, 1                   (= %n1 (sub i64 %n 1))
  %f = call i64 @fact(i64 %n1)          (= %f (call i64 (@fact (i64 %n1))))
  %r1 = mul i64 %n, %f                  (= %r1 (mul i64 %n %f))
  ret i64 %r1                           (ret i64 %r1)))
}
```

Listed vertically it reads as assembly, per the vision: labels sit one
indent level left of their instructions.

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

- Every instruction lives in exactly one block group
  `(label %x <insn> ... <terminator>)`; a bare instruction at body level is
  an error. The first group is the entry block (conventionally `%entry`).
- Labels may be referenced before their group appears (forward branches,
  phi incoming) — building creates all blocks in a prepass.
- ll itself checks: instruction outside a block, empty block, block not
  ending in `ret`/`br` (grows with the terminator set), nested blocks,
  duplicate labels and `%` names (SSA). LLVM's verifier backstops the rest.

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

- pass 1 per function: create the function and a basic block per
  `(label %x ...)` group (forward references);
- pass 2: emit each group's instructions via (llvm ir) builders, resolving
  `%`/`@` names through per-function/per-module environments (hashtables);
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
