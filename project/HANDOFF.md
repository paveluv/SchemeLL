# SchemeLL — hand-off / ramp-up notes

Context for continuing work on this repo that is NOT obvious from the
tree: hard-won LLVM/Chez knowledge, methodology, and direction.
Maintained alongside the code; last full pass 2026-08-24. Reading
order: `README.md`, `project/RULES.md`, then this.

## What this project is (and where it's going)

LLVM 19 bindings for Chez Scheme plus **sll** ("Scheme's Low Level"),
a complete s-expression dialect of LLVM IR. Terminology is strict:
**ll** = LLVM IR itself (`.ll` files, in-memory modules); **sll** = its
Scheme counterpart. The project is a **lowering target** for compilers
written in Scheme.

Not in this repo, planned as separate repos (do not add here, do not
mention in README): **medl**, a Scheme-like typed language lowering to
sll; and the first target application, a **highly efficient garbage
collector**. Everything the GC needs from IR is already modeled
(statepoints, tokens, "gc-live"/"deopt" bundles, gc attribute,
datalayout `ni:1`, addrspace(1) pointers). Remaining GC prerequisites
live OUTSIDE sll: stack-map (`.llvm_stackmaps`) section access from
the ORC JIT (an object-linking-layer hook) and safepoint polls.
(Calling conventions — tailcc/fastcc/ghccc/`(cc N)` — WERE the third
gap; modeled 2026-08-24 as the first Meik Scheme prerequisite, see
sll-design.md.) Statepoint flow knowledge: you do NOT hand-write
relocation chains — the frontend emits clean addrspace(1) IR with `gc`
attributes, `RewriteStatepointsForGC` runs LATE and inserts
statepoints/relocates mechanically, codegen emits the stack maps.
`gc.statepoint` calls carry a verifier-mandated `elementtype`
attribute on the callee arg (which is why the statepoints golden uses
the normalized-entry kind).

## Current state

- **Coverage campaign COMPLETE** (project/coverage-plan.md): 35k+ of
  LLVM's own 36,488-file regression corpus round-trips byte-identically
  (98.9% of parseable); zero unexplained failures; every remaining file
  is in a named bucket in project/not-modeled.md, each a documented
  C-API gap. Agreed definition of 100%: *utilizing the C API to full
  potential*. Ledger invariant: implemented ∪ documented = LLVM IR;
  modeling something later = delete its ledger row + its normalizer
  strip, and the corpus starts testing it.
- **252 checks** (`make test`), **37 examples** (`make examples`),
  all green. A large bug hunt (two review agents + adversarial probes)
  just fixed 15 reproduced defects; regressions exist for each.
- **Tested platforms**: x86-64 Linux and x86-64 FreeBSD (user-verified,
  including `--exe` executables), LLVM 19 only. Newer LLVM planned:
  the version pin lives entirely in `llvm/config.sls` + `llvm/raw.sls`.

## The stack, one line each

- `llvm/config.sls` — version pin; auto-detects header dir (Debian /
  FreeBSD port / generic) and loads `libLLVM-19.so`.
- `llvm/raw.sls` — C API verbatim; `(prefix (llvm raw) LLVM)`
  reconstructs exact C names. 233 foreign procedures + enum constants.
- `llvm/base.sls` — error raising + **LLVM diagnostic capture** (see
  quirks below); `base:error` attaches drained diagnostics to whatever
  it raises.
- `llvm/ir.sls` — ownership-tracked records (use-after-dispose raises,
  guardians reclaim); thin wrappers.
- `llvm/jit.sls` — ORC LLJIT; FFI signatures derived from LLVM types;
  process-symbol resolution (libc callable); **refuses modules with a
  foreign triple** (arch+OS compared, vendor ignored).
- `llvm/target.sls` — objects/asm, host or cross
  (`initialize-target!` by backend name); machine-type → backend map
  includes a6le/ta6le/a6fb/ta6fb.
- `sll.sls` — build/jit/procedure/dump/unbuild/load-sll. Two build
  passes per program + per-function block pre-pass (cross-function
  blockaddress); alias/ifunc two-phase creation (print order =
  creation order).
- `sll/unbuild.sls` — module → sll data; strict not-modeled errors;
  `'ignore-named-metadata`, `'tolerate-builder-folds` opts.
- `sll/render.sls` — `sll->ll`: textual IR in pure Scheme (used by the
  corpus render tier and `sllc --render-llvm-ir`).
- `sll/asm.sls` — `asm:expr`: structured inline asm (named operands,
  computed `${N}` numbering, assembled constraints; leaf codes pass
  through uninterpreted).
- `tools/sllc.ss` + `tools/sllc` wrapper — the `.sll` compiler:
  `.o`/`.s`/`--run`/`--exe` (minimal ELF64 emitter, x86-64 Linux or
  FreeBSD host only, OSABI-branded)/`--render-llvm-ir`/
  `--print-canonical`. Strict arg parsing; output never overwrites
  input. `--run` calls `@main` (0-arg or argc/argv) and falls back to
  `@_start` — flushing Scheme's output ports FIRST, because a noreturn
  entry exits via exit_group and buffered output would vanish.
- `.sll` files are the **inverted format**: top level is sll data,
  Scheme escapes in via `,`/`,@` + top-level `(scheme ...)` forms
  (defines AND imports). Escapes evaluate strictly top-to-bottom.
  A .sll with escapes is a program — trust required.

## Conventions (RULES.md is authoritative; highlights)

- ALL project imports prefixed (`ir:`, `jit:`, `sll:`, `render:`,
  `asm:`, `base:`, `config:`, `target:`, `n:`, `t:`); definitions
  never carry module prefixes; no export renames.
- Modules raising errors define a LOCAL `error` wrapping `base:error`
  with the module's who (`sll:build`, `sll:unbuild`, ...). The corpus
  classifier matches on these who symbols — renaming one breaks
  tests/corpus.ss classification.
- `~/.e/tools/scheme-format -i` runs in the pre-commit hook
  (project/hooks). It REFORMATS: after `make format`, exact-string
  anchors in files may change. Commits abort if it reformats — re-add
  and commit again.
- Commit style: imperative subject, story-telling body, **NO
  Co-Authored-By trailers** (user's global rule). Multi-line messages
  via `git commit -F -` heredoc (backticks in `-m` get shell-expanded).
- The user tests on FreeBSD themselves; keep BSD make compatibility
  (no `$(shell ...)` — use `!=`; recipes are plain sh).

## The methodology that works here

1. **Empirical probes before code.** Never trust the header docs or
   memory of LLVM behavior: write a 10-line Scheme probe first. Most
   modeling wins came from probes (flag getters working on constexprs,
   printer numbering rules, parser vs builder defaults).
2. **The corpus is the oracle.** After any grammar change:
   `make corpus` (needs `make reference` once), inspect bucket deltas,
   `tests/tmp/corpus-buckets.txt` has per-file paths,
   `tests/probe-mismatch.ss` histograms first-diff lines for MISMATCH.
   Zero MISMATCH/BUG is the invariant to restore before committing.
3. **Golden entries pin every feature** through THREE paths: build,
   unbuild round-trip, render round-trip (tests/test-coverage.ss;
   `check-normalized-entry!` for constructs needing auto-attributed
   intrinsic declarations).
4. **Patch-script discipline**: repo edits in this project's history
   were applied by python heredocs with exact-string asserts. When an
   assert fails, NOTHING in that script was written — verify each edit
   landed (grep) before building on it. Two real bugs shipped this way
   and were caught later by the harness.
5. Every new execution path for the same program is a free oracle
   (running hellos under --run exposed a junk exit status; the DSL
   exposed the empty-constraint segfault).

## LLVM quirks catalog (hard-won; do not re-derive)

- **IRBuilder constant-folds** all-constant instructions and no-op
  casts; the C API has no NoFolder. The corpus handles this via the
  render tier (LLVM's parser as the non-folding constructor) +
  fixpoint fallback. `ConstantExpr::get` folding IS symmetric with the
  parser (bitcast folds bit-exactly both directions for every float
  type except ppc_fp128 — that's how NaN payloads are modeled:
  `(bitcast i16 31745 half)`).
- **Constexprs are uniqued per context** — pointer-compare a
  reconstruction to verify a shape you cannot read via the C API
  (that's how splats are recognized; the shuffle MASK of a constexpr
  is unreadable).
- The printer numbers unnamed values/blocks/types **by first use in
  print order**; sll's anonymity rule (all-digit names stay unnamed)
  exists so both sides number identically. Metadata ids and `<0x...>`
  pointer forms are print artifacts — the harness canonicalizes them
  densely by first occurrence.
- `target datalayout`/`triple` lines must precede ALL other entities
  or the parser rejects the file.
- Parser and builder both apply datalayout defaults: functions get the
  `P` program space, builder allocas get `A` (parser allocas do NOT);
  `LLVMAddGlobal` uses `G` — sll always passes explicit spaces.
- `LLVMGetAlignment` returns 0 for 2^32 (LLVM's max) — harness detects
  textually. `LLVMConstRealGetDouble` under-reports loss for
  ppc_fp128 — verify by print. `LLVMIsAMDNode` claims ValueAsMetadata
  too — test `LLVMIsAValueAsMetadata` first. `LLVMStripModuleDebugInfo`
  segfaults on malformed debug info — guarded in the normalizer, which
  also deletes the dead `llvm.dbg.*` declarations it leaves behind.
- **Mismatched inline-asm constraint counts SEGFAULT LLVM** (no
  verifier check) — `check-asm-arity` in sll.sls guards; `$N` operand
  errors in templates go through `report_fatal_error` = process abort,
  unfixable. Inline-asm mnemonic errors report SUCCESS + an
  error-severity diagnostic — hence the capture machinery in base.sls
  and `check-diagnostics!` after emission/materialization.
- No C API exists for: distinct metadata nodes, `inrange` on gep
  constexprs, partitions, thread_local on aliases, code_model on
  globals, prefix/prologue data reading — all detected (textually
  where needed) and ledgered.
- Inline asm is strings all the way down (template + constraint blob;
  same in textual IR, C++ API, bitcode). LangRef fully specifies the
  constraint STRUCTURE (=, =&, tied digits, ~{clobbers}, {regs},
  ordering) but the leaf letters are per-target, GCC-deferential, and
  "implemented as needed" — which is why (sll asm) validates structure
  and passes leaves through uninterpreted.
- Verified LLVM 19 surviving constexpr set: the five casts
  (trunc/ptrtoint/inttoptr/bitcast/addrspacecast), add/sub/mul/xor
  (single wrap flag only — no C constructor sets both nuw+nsw),
  getelementptr, extract/insertelement, shufflevector (mask
  unreadable). zext/sext/icmp/select/and/shl are GONE upstream and
  the set shrinks each release.
- Fixed-vector splats FOLD to plain constant vectors at construction;
  only scalable-vector splats survive as constexprs (hence
  `(splat (ty elem))` and the pointer-compare recognition).
- `musttail` prints a literal `...` in the ARGUMENT list iff both
  caller and callee are varargs — the renderer derives it, LLVM does
  not store it.
- The parser ACCEPTS inline metadata nodes in call args
  (`metadata !{!"sp"}`) though the printer always emits numbered refs.
  MDString lengths are BYTES, not characters (utf8 bug class).
- `LLVMGetOperandBundleAtIndex` returns a FRESH ref the reader must
  dispose (unlike most getters). `AliasSetAliasee` /
  `SetGlobalIFuncResolver` enable two-phase creation; aliases and
  ifuncs PRINT in creation order, so program order must be creation
  order (create with placeholders, patch after).
- Token-typed forward references cannot use the freeze-of-undef
  placeholder (freeze rejects tokens); the placeholder is a parentless
  scratch-block `cleanuppad`, RAUW'd and erased like the rest.
- The anonymity rule covers values, blocks, TYPES (`%0 = type`), and
  is *violated* by explicit digit-string names (`%"0"`, `@"0"`) —
  detected, inexpressible by design.
- Non-ASCII byte arrays: `(c "...")` is ASCII-only; unbuild falls back
  to per-element `(i8 N)` groups, which LLVM re-canonicalizes to the
  identical constant.
- Personalities are ANY ptr constant (the corpus contains
  `personality i1 1` and `personality ptr inttoptr(i64 1 to ptr)`).
- LLVM's TypeFinder walks named metadata, so type DEFINITIONS can
  print with zero uses in retained text — the harness drops
  unreferenced type-def lines to a fixpoint. `; preds =` comments
  reflect use-list order, which RAUW fixups legitimately permute —
  stripped from comparisons.
- `i1` maps to Chez `boolean` at the FFI: Scheme `0` is TRUTHY —
  pass `#f`.

## Chez quirks catalog

- `foreign-callable` code objects must be `lock-object`'d before
  taking their entry point (the diagnostic callback). NEVER raise
  inside a C→Scheme callback — it unwinds through LLVM's C++ frames;
  capture and re-raise from the Scheme side (base.sls pattern).
- `copy-environment` of `(environment '(chezscheme))` with #t gives a
  mutable env where `eval`'d defines AND imports work — how `.sll`
  `(scheme ...)` forms run.
- Chez has a BUILT-IN `load-program` (R6RS program loader) — that's
  why ours is `load-sll`; an unprefixed double import silently
  shadowed it with baffling errors.
- Chez `format`/`printf` support CL-style `~{...~}` iteration.
- `machine-type` table used here: a6le/ta6le (x86-64 Linux),
  a6fb/ta6fb (FreeBSD amd64), arm64le/tarm64le; `t` prefix = threaded.
  FreeBSD packages the binary as `chez-scheme` (auto-detected in
  Makefile via `!=`, in tools/sllc via command -v; BSD make has no
  `$(shell ...)`).
- Compiled library objects (`.so`, Chez objects not ELF) are reused
  automatically when newer than sources; `--compile-imported-libraries`
  creates them on first use (tools/sllc does this; `make build` does
  the whole tree; ~6x faster startup, measured).

## Useful measured numbers

- IR construction ~150 µs/module (corpus bench, printed every
  `make corpus` run); render+parse ≈ 3.9× direct builder cost.
- `sll:procedure` end to end ≈ 20 ms warm (each call spins its own
  LLJIT). Cold script ≈ 1 s interpreted vs ≈ 0.15 s with compiled
  libraries.
- The freestanding hellos: 194 bytes (16-aligned .text; the earlier
  184/186 predates the alignment fix).

## Env setup on a new machine

Chez 10 (`scheme` or `chez-scheme`, auto-detected) + LLVM 19 with
headers. Then: `make build` (compile libs, ~6x faster startups),
`make test` (252), `make examples` (37), `make reference` (sparse
llvm-project clone for `make corpus`; `git sparse-checkout add
llvm/docs` inside it for LangRef). `tools/sllc` is self-compiling.
Platform facts: FreeBSD's image activator REJECTS unbranded SYSV
ELF executables — sllc brands e_ident[EI_OSABI] per host (9 there);
BSD syscall numbers differ from Linux (write=4, exit=1, vs 1/231;
arm64 Linux: 64/94 via svc #0/x8). macOS was deliberately not
targeted by --exe: Mach-O + mandatory ad-hoc code signing on Apple
Silicon + raw syscalls being an unstable ABI there; hello-libc.sll
+ --run is the portable demo instead.

ELF emitter lessons (`--exe`): place `.text` at a file offset honoring
`sh_addralign` — an earlier version used the first free offset (0x78,
8 mod 16) and a `.balign 16`-assuming access (movaps class) SIGSEGV'd;
the fix is why executables are 194 bytes with entry 0x400080. Sections
are judged by FLAGS, not names: any SHF_ALLOC PROGBITS/NOBITS data
section is refused (one RX PT_LOAD only, no relocations applied), while
non-alloc and `.eh_frame`/X86_64_UNWIND drop silently.

## Open threads / natural next steps

1. GC runtime groundwork: `.llvm_stackmaps` access from ORC (object
   linking layer hook), safepoint polls, then the allocator/barriers —
   in the future GC repo, driven from here.
2. ~~Calling conventions in sll~~ DONE 2026-08-24 (define/declare
   headers, call/invoke/callbr sites, named + `(cc N)`).
3. LLVM 20 support: re-run the oracle + corpus against a new pin;
   constexpr kinds shrink again upstream.
4. medl design (separate repo): nanopass over sll; sll grammar was
   deliberately built prefix-only/no-mid-form-keywords for this.
5. Maybe: `sllc --triple` flag (cross flags exist internally),
   stack-map-friendly `--exe` data sections, Mach-O output (decided
   AGAINST for now — Apple Silicon requires code signing).
