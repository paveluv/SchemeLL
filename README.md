# llscheme

LLVM bindings for Chez Scheme, plus (eventually) a Scheme-embedded,
statically-typed DSL compiled through LLVM.

What works today:

- **`(llvm raw)`** — direct FFI bindings to the LLVM 19 C API (curated subset).
- **`(llvm ir)`** — safe IR construction: contexts/modules/builders as records
  with ownership tracking (use-after-free raises instead of segfaulting).
- **`(llvm jit)`** — ORC LLJIT: compile modules fully in memory and get JIT'd
  functions back as ordinary Scheme procedures, with the foreign signature
  derived automatically from the function's LLVM type. No files touched.
- **`(llvm target)`** — object file / assembly emission, to disk or to a
  bytevector; new-pass-manager optimization via `run-module-passes!`.

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

`(llvm jit)` is meant to be imported with a prefix (its exports carry no
prefix of their own); for the other libraries the prefix is the importer's
choice, as usual in R6RS.

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
