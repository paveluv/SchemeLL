# Project rules and procedures

## What this project is

`llscheme` — LLVM bindings for Chez Scheme, in four layers:

| Layer | Library | Contents |
|-------|---------|----------|
| 0 | `(llvm raw)` | 1:1 `foreign-procedure` bindings to the LLVM C API. No logic. |
| 0 | `(llvm config)` | The ONLY file that knows the LLVM version and shared-object name. |
| 1 | `(llvm base)` | FFI utilities: C strings, out-params, pointer arrays, error → condition. |
| 1 | `(llvm ir)` | Safe handles (context/module/builder records with ownership state), IR construction. |
| 1/2 | `(llvm target)` | Native target init, target machines, object/assembly emission. |
| 2 | `(llvm jit)` | ORC LLJIT: compile modules in memory, look up functions as ready-to-call Scheme procedures. |
| 3 | `(llscheme ll)` | LLVM IR as s-expressions (`project/ll-design.md`): data interpreter over an opcode table; `build`/`jit`/`dump`/`unbuild`. `(llscheme ll unbuild)` is its internal inverse-walker; it reads through `(llvm raw)` getters directly — read-only walks over borrowed pointers carry none of the ownership hazards `(llvm ir)` fences. Everything unbuild cannot represent is ledgered in `project/not-modeled.md`. |
| 4 | `(llscheme medl)` | (future) nanopass-based structured DSL, compiling down to ll. Working code name DECIDED 2026-08-22: "medl" (MEDium Language, pronounced like "medal"); essentially collision-free. |

## Naming and namespaces

- Definitions never carry a module prefix (no `jit-make`, no `target-emit-...`),
  and export clauses contain no renames. Namespacing is entirely the importer's
  job, via R6RS `prefix` imports.
- ALL imports of project libraries are prefixed, everywhere (libraries, tests,
  examples, docs), with these canonical prefixes:
  `config:` `base:` `ir:` `target:` `jit:` `ll:` `medl:` (future) `t:`
  (tests harness), and
  `(prefix (llvm raw) LLVM)` — no colon, so layer-0 call sites reconstruct the
  exact C names (`LLVMBuildAdd`) and read side by side with the headers.
- `(chezscheme)` / `(rnrs)` are imported unprefixed; that is the only exception.
- Record-type prefixes within a library are fine and encouraged
  (`context-dispose!`, `module->string`, `machine-triple`): they name the record,
  not the module.
- Condition `who` values: liveness errors use the record name (`'module`,
  `'machine`, `'jit`); operation errors use the caller-facing prefixed name
  (`'jit:add-module!`, `'target:emit-to-file`, `'ir:verify-module`).
- `base:error` is the project's error raiser (today equivalent to R6RS `error`;
  will grow a dedicated `&llvm` condition type). `(llvm base)` imports
  `(except (chezscheme) error)` to define it.

## Environment pins

- **LLVM 19** (`libLLVM-19.so`, Debian package). Version-specific knowledge goes in
  `llvm/config.sls` and `llvm/raw.sls` ONLY.
- **Chez Scheme 10.0**, machine type `ta6le` (x86_64 Linux, threaded).
- 64-bit platform is assumed in `(llvm base)` (pointers are 8 bytes).

## FFI conventions (layer 0)

- `(llvm raw)` definitions drop the leading `LLVM`; importing with
  `(prefix (llvm raw) LLVM)` restores the exact C names at call sites, and the
  `foreign-procedure` entry strings keep the full names, so grepping a C name
  finds both the binding and its uses.
- Type mapping: every `LLVM*Ref` → `void*` (an exact integer address; 0 = NULL);
  `const char*` input → `string`; `char*` that the caller must dispose → `void*`
  (convert with `cstring->string/dispose`); `LLVMBool` and enums → `int`;
  `unsigned` → `unsigned-int`; `uint64_t` → `unsigned-64`; `size_t` → `size_t`;
  out-params and pointer arrays → `void*` pointing at `foreign-alloc`'d memory.
- Since LLVM 15 all pointers are opaque: always the `*2` builder variants
  (`LLVMBuildCall2`, `LLVMBuildLoad2`, `LLVMBuildGEP2`), and
  `LLVMGlobalGetValueType` (not `LLVMTypeOf`) to get a function's type.

## Ownership rules (layer 1) — the load-bearing discipline

A dangling pointer takes down the whole Chez session, so:

- Owning handles (context, module, builder, target machine, JIT, memory buffer) are
  wrapped in records with a mutable `state` field: `owned` | `borrowed` | `consumed`
  | `disposed`. Every use goes through an accessor that raises if not live.
- Borrowed pointers (types, values, basic blocks) are passed around as raw addresses.
  They live as long as their context; no wrapping.
- Ownership transfers we rely on (verified against LLVM 19 headers):
  - `LLVMOrcCreateNewThreadSafeModule` consumes the module (context is shared/refcounted).
  - `LLVMOrcLLJITAddLLVMIRModule` consumes the ThreadSafeModule, even on error.
  - After adding a module to the JIT, the module record's state becomes `consumed`.
- Every `char*` returned by LLVM that we own must be released with
  `LLVMDisposeMessage` (or `LLVMDisposeErrorMessage` for error strings). Do the
  convert-and-dispose in one call: `cstring->string/dispose`.
- JIT'd code lifetime: procedures returned by `jit:function` close over the jit
  record, so the LLJIT instance stays reachable (and its code mapped) as long as any
  generated procedure is alive. Unreachable jits are disposed lazily by a guardian.
- Dispose order: builders before modules before contexts.

## Formatting

- All Scheme sources (`*.sls`, `*.ss`) are formatted with
  `~/.e/tools/scheme-format` (`-i` for in-place). `make format` formats every
  tracked Scheme file.
- Formatting is enforced pre-commit: the hook in `project/hooks/pre-commit`
  formats the staged Scheme files and aborts the commit if anything changed
  (review, `git add`, commit again).
- One-time setup per clone: `git config core.hooksPath project/hooks`.

## Procedures

- Run tests: `make test` (runs `scheme --libdirs . --script tests/run.ss`).
- REPL with libraries visible: `make repl`.
- Tests write temp files only under `tests/tmp/` (gitignored).
- Work tracking lives in `project/WORKLOG.md`: dated entries, "Done / Decided / Next".
  Update it at the end of every working session.
- Commit style: imperative subject line; no Co-Authored-By trailers.

## The `reference/` directory

`reference/` is **gitignored** local material we download once instead of re-fetching
from the internet every time. Every subdirectory must be documented here with the
exact command/URL to recreate it.

| Path | How to (re)create | Purpose |
|------|-------------------|---------|
| `reference/llvm-project/` | `git clone --depth 1 --branch llvmorg-19.1.7 https://github.com/llvm/llvm-project.git reference/llvm-project` | LLVM sources: C API implementation (`llvm/lib/*/`*-c*`.cpp`), ORC internals, docs (`llvm/docs/`). |
| `reference/ChezScheme/` | `git clone --depth 1 --branch v10.0.0 https://github.com/cisco/ChezScheme.git reference/ChezScheme` | Chez sources, incl. FFI implementation. |
| `reference/csug/` | `wget -r -np -k -P reference/csug https://cisco.github.io/ChezScheme/csug10.0/csug.html` | Chez Scheme User's Guide (FFI chapter: `foreign.html`). |
| `reference/nanopass/` | `git clone https://github.com/nanopass/nanopass-framework-scheme.git reference/nanopass` | Nanopass framework, for layer 3. |
| `reference/sham/` | `git clone https://github.com/rjnw/sham.git reference/sham` | Racket's Sham: prior art for an LLVM DSL in a Scheme. |

Note: the LLVM **C API headers are already installed** at
`/usr/include/llvm-c-19/llvm-c/` — that is the primary reference for signatures,
enums, and ownership comments. Check there before cloning llvm-project.
