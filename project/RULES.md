# Project rules and procedures

## Error raising

`base:error` is the project's raw error raiser. Modules that raise
their own errors define a LOCAL `error` wrapping it with the module's
`who` (importing `(except (chezscheme) error)`), e.g. `(sll)` raises
with who `sll:build`. No pseudo-namespace helper names (`sll-error`,
`u-error`): the namespace comes from the import site, never from the
definition -- the same rule as for exports.

## Terminology

- **ll** refers to LLVM IR itself -- the textual language in `.ll`
  files and the in-memory modules.
- **sll** ("Scheme's Low Level") refers to its Scheme counterpart: the
  s-expression representation defined by `(sll)` and
  `project/sll-design.md`. `sll:build` interprets sll into IR;
  `sll:unbuild` reads IR back into sll; `(sll render)`'s `sll->ll`
  prints sll as textual ll without LLVM's help.
- The project name is **SchemeLL**.

## What this project is

`SchemeLL` — LLVM bindings for Chez Scheme, in four layers:

| Layer | Library | Contents |
|-------|---------|----------|
| 0 | `(llvm raw)` | 1:1 `foreign-procedure` bindings to the LLVM C API. No logic. |
| 0 | `(llvm config)` | Installation selection, exact release verification, and C API capability facts. |
| 1/2 | `(llvm jit-layout)` | Version-qualified LLJIT admission compatibility; preserves non-integral layouts through code generation. |
| 1 | `(llvm base)` | FFI utilities: C strings, out-params, pointer arrays, error → condition. |
| 1 | `(llvm ir)` | Safe handles (context/module/builder records with ownership state), IR construction. |
| 1/2 | `(llvm target)` | Native target init, target machines, object/assembly emission. |
| 2 | `(llvm jit)` | ORC LLJIT: compile modules in memory, look up functions as ready-to-call Scheme procedures. |
| 3 | `(sll)` | LLVM IR as s-expressions (`project/sll-design.md`): data interpreter over an opcode table; `build`/`jit`/`dump`/`unbuild`. `(sll unbuild)` is its internal inverse-walker; it reads through `(llvm raw)` getters directly — read-only walks over borrowed pointers carry none of the ownership hazards `(llvm ir)` fences. Everything unbuild cannot represent is ledgered in `project/not-modeled.md`. |
| 4 | `(SchemeLL medl)` | (future) nanopass-based structured DSL, compiling down to ll. Working code name DECIDED 2026-08-22: "medl" (MEDium Language, pronounced like "medal"); essentially collision-free. |

## Naming and namespaces

- Definitions never carry a module prefix (no `jit-make`, no `target-emit-...`),
  and export clauses contain no renames. Namespacing is entirely the importer's
  job, via R6RS `prefix` imports.
- ALL imports of project libraries are prefixed, everywhere (libraries, tests,
  examples, docs), with these canonical prefixes:
  `config:` `base:` `ir:` `target:` `jit:` `sll:` `medl:` (future) `t:`
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

- **LLVM 19.1.7 / 20.1.8**, with 19 as the default. Pure installation selection
  lives in `llvm/selection.sls`; hosted loading/version facts and named capabilities
  live in `llvm/config.sls`; C signatures in `llvm/raw.sls`;
  compatibility behavior lives in SchemeLL's adapters. Higher layers query
  named capabilities rather than distributing numeric version tests. Woof owns
  its runtime qualification, and Meik owns neither set of version branches.
  See [version selection and qualification](llvm-versions.md).
  Only an explicitly installed hosted adapter may read environment settings;
  backend libraries consume Scheme selections.
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

- All tracked Scheme sources (`*.sls`, `*.ss`, `*.scm`, `*.sps`, and `*.sll`)
  are formatted with [Schematter](../schematter/README.md), pinned as the
  `schematter/` submodule. `make format` formats them in place;
  `make check-format` checks without writing.
- Initialize the formatter with `git submodule update --init --recursive`,
  or clone SchemeLL with `--recurse-submodules`.
- Formatting is enforced pre-commit: the hook in `project/hooks/pre-commit`
  launches `project/hooks/pre-commit.sps`, which uses `(schematter hook)`
  to format staged Scheme files (including `.sll`) and Scheme code blocks
  in `.md` and `.markdown` files. It aborts the commit if anything changed
  or could not be formatted (review, `git add`, commit again). The launcher
  honors `CHEZ` and detects `scheme` or `chez-scheme` like the Makefile.
- One-time setup per clone: `git config core.hooksPath project/hooks`.

## Procedures

- Run tests: `make test` (runs `scheme --libdirs . --script tests/run.ss`).
- Corpus round-trip (coverage level 3): `make corpus` (needs
  `reference/llvm-project`; `CORPUS_DIR=...` to scope to a subdirectory).
  Buckets and strategy: `project/coverage-plan.md`; the normalizer lives
  in `tests/normalize.sls`.
- REPL with libraries visible: `make repl`.
- Tests write temp files only under `tests/tmp/` (gitignored).
- Work tracking lives in `project/WORKLOG.md`: dated entries, "Done / Decided / Next".
  Update it at the end of every working session.
- Commit style: imperative subject line; exact-model Co-Authored-By trailers
  as required by AGENTS.md.

## The `reference/` directory

`reference/` is **gitignored** local material we download once instead of re-fetching
from the internet every time. Every subdirectory must be documented here with the
exact command/URL to recreate it.

| Path | How to (re)create | Purpose |
|------|-------------------|---------|
| `reference/llvm-project/` | `make reference` (a pinned sparse clone: `--branch llvmorg-19.1.7 --filter=blob:none --sparse`, checkout `llvm/test`) | LLVM's regression corpus for `make corpus` (36k .ll files); widen the sparse checkout for sources/docs when needed (`git sparse-checkout add llvm/docs` for LangRef). |
| `reference/ChezScheme/` | `git clone --depth 1 --branch v10.0.0 https://github.com/cisco/ChezScheme.git reference/ChezScheme` | Chez sources, incl. FFI implementation. |
| `reference/csug/` | `wget -r -np -k -P reference/csug https://cisco.github.io/ChezScheme/csug10.0/csug.html` | Chez Scheme User's Guide (FFI chapter: `foreign.html`). |
| `reference/nanopass/` | `git clone https://github.com/nanopass/nanopass-framework-scheme.git reference/nanopass` | Nanopass framework, for layer 3. |
| `reference/sham/` | `git clone https://github.com/rjnw/sham.git reference/sham` | Racket's Sham: prior art for an LLVM DSL in a Scheme. |

The selected installation's **C API headers** are the primary reference for
signatures, enums and ownership comments. Use `(llvm config)`'s
`header-directory` and `validate-headers!` to ensure they match the loaded
library. On this Debian host, both releases are installed under
`/usr/lib/llvm-N/include/llvm-c/`. Check the matching headers before cloning
llvm-project. The S5 corpus/source checkout procedure is in
[version qualification](llvm-versions.md).
