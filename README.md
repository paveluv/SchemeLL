# SchemeLL

LLVM bindings for Chez Scheme, plus (eventually) a Scheme-embedded,
statically-typed DSL compiled through LLVM (working name: medl).

What works today:

- **`(llvm raw)`** — direct FFI bindings to the LLVM 19 C API (curated subset).
- **`(llvm ir)`** — safe IR construction: contexts/modules/builders as records
  with ownership tracking (use-after-free raises instead of segfaulting).
- **`(llvm jit)`** — ORC LLJIT: compile modules fully in memory and get JIT'd
  functions back as ordinary Scheme procedures, with the foreign signature
  derived automatically from the function's LLVM type. No files touched.
- **`(llvm target)`** — object file / assembly emission, to disk or to a
  bytevector; new-pass-manager optimization via `run-module-passes!`.
- **`(sll)`** — LLVM IR as s-expressions: textual IR transliterated
  into plain Scheme data (see `project/sll-design.md`), interpreted into real
  IR. Since programs are lists, quasiquote is the metaprogramming layer.
  `sll:procedure` compiles a program in memory and returns a Scheme
  procedure; `tools/sllc.ss` compiles `.sll` files to objects — or, for
  self-contained programs, straight to a static executable with no
  external toolchain at all. Start at `examples/README.md`.

```scheme
(import (prefix (sll) sll:) (prefix (llvm jit) jit:))

(define fact-prog
  '((define i64 (@fact (i64 %n))
      (label %entry
        (= %isbase (icmp slt i64 %n 2))
        (br i1 %isbase (label %base) (label %rec)))
      (label %base
        (ret i64 1))
      (label %rec
        (= %n1 (sub i64 %n 1))
        (= %f (call i64 (@fact (i64 %n1))))
        (= %r (mul i64 %n %f))
        (ret i64 %r)))))

(define fact (jit:function (sll:jit fact-prog) "fact"))
(fact 20)                ; => 2432902008176640000
(display (sll:dump fact-prog))   ; the same program as textual LLVM IR
```

```scheme
(import (prefix (llvm ir) ir:)
        (prefix (llvm jit) jit:))

(define jc (jit:make-context))
(define ctx (jit:context-ir jc))
(define mod (ir:make-module ctx "demo"))
(define b (ir:make-builder ctx))

(define i32 (ir:int32-type ctx))
(define f (ir:add-function mod "add" (ir:function-type i32 (list i32 i32))))
(ir:position-at-end! b (ir:append-block ctx f "entry"))
(ir:build-ret b (ir:build-add b (ir:function-param f 0) (ir:function-param f 1)))

(define j (jit:make))
(jit:add-module! j jc mod)

(define add (jit:function j "add"))  ; a plain Scheme procedure
(add 3 4)                            ; => 7
```

Project-wide naming convention: definitions carry no module prefix, and every
project library is imported with a `prefix` (`ir:`, `jit:`, `target:`, `base:`,
`config:`). `(llvm raw)` is imported as `(prefix (llvm raw) LLVM)`, which makes
call sites read as the exact C names (`LLVMBuildAdd`, ...). See
`project/RULES.md`.

## Requirements

- Chez Scheme 10, 64-bit Linux (x86_64 or aarch64)
- LLVM 19 shared library (`libLLVM-19.so`, e.g. Debian's `libllvm19`)

## Running

```
make test    # run the test suite
make repl    # REPL with the libraries on the library path
```

## Project docs

- `project/RULES.md` — layering, FFI conventions, ownership rules, reference material.
- `project/WORKLOG.md` — work tracking.
