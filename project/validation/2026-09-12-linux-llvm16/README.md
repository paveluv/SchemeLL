# LLVM 16 qualification on Debian x86-64, 2026-09-12

Reviewed SchemeLL `07cfbb09650645e1564d70be8b7a77ba62c7dffe`
("Qualify LLVM 16 for typed-pointer bitcode") and repaired the compatibility
gaps found during review and a complete matching-corpus run. The compatibility
commit was then rebased onto upstream
`9c7049fd1796e581cc03be66d567f00542785d8f` ("Add the typed pointer type form
and named metadata"). All final logs below were refreshed after that rebase;
they cover upstream plus the rebased compatibility fixes and regression tests.
The root README's "Tested platforms" table records this validation.

The rebase resolved one conflict in `llvm/raw.sls`, retaining both
`AddNamedMetadataOperand` and `GetMetadataKind`, with a single `ValueAsMetadata`
binding and export. A range comparison confirmed this was the only adjustment
to the compatibility code during rebase. No additional implementation fixes
were needed after the complete rerun.

## Initial findings, now fixed

These findings describe the original commit. Their source line numbers refer
to that commit, before the fixes moved the readers into `llvm/text-flags.sls`.

1. **P1: operand bundles disappear when the call has attributes.**
   `sll/unbuild.sls:963` searches for the exact text `) [ "`, but LLVM prints
   a call-site attribute group between the argument list and the bundle:
   `call void @g() #0 [ "deopt"(i32 7) ]`. On LLVM 16, unbuild misses the
   bundle and returns an ordinary call; rebuilding silently drops the deopt
   state. The same call without `nounwind` is correctly refused as
   not modeled. Both inputs verify with LLVM. On 19 and 20, both bundles
   survive the round trip. Detection must account for intervening attributes.

2. **P1: prefix/prologue data can disappear, and quoted names can be falsely
   refused.** `llvm/ir.sls:747` stops scanning at the first newline or `{`.
   `LLVMPrintValueToString` puts a `; Function Attrs: nounwind` comment before
   the definition, so attributed functions' actual headers are never scanned.
   A literal struct return type also ends the scan prematurely. Verified
   functions with `prefix i32 123` or `prologue i32 123` then unbuild and
   rebuild without their data instead of raising the documented refusal.
   Conversely, `@"a prefix b"` without prefix data is rejected. On 19 and 20,
   the actual decorations are refused and the quoted name round-trips.
   Detection must locate the definition header, distinguish type braces from
   the body, and ignore quoted names and strings.

3. **P2: metadata-bearing fences break ordering inspection.**
   `llvm/ir.sls:1443` interprets the last Scheme datum in the printed fence as
   its ordering. For verified `fence acquire, !annotation !0`, the last datum
   is `!0`, and `ir:instruction-ordering` raises `unreadable fence ordering`
   instead of returning 4. Both 19 and 20 return 4. Read the ordering before
   trailing metadata, respecting quoted synchronization scopes.

[review.ss](review.ss) contains executable checks for these cases. On the
original commit it reported **3 passed, 6 failed on LLVM 16**, retained in
`review-before-llvm16.log`. The final code passes **9/9 on 16 and 8/8 on
each of 19 and 20**. Four initial failures cover the different header
scanner cases; the other two cover attributed bundles and fence metadata.
It also checks quoted instruction names, integer and fast-math flag reading,
and disassembles newly written typed-pointer bitcode with LLVM 16's
`llvm-dis -opaque-pointers=0`. The latter succeeds with
`float addrspace(1)*` preserved.

The focused script is retained as review evidence, separate from `make test`.
It exits 1 when a check fails. Its initial LLVM 16 log includes verified
before/after IR showing the silent losses. The normal suite now includes
25 checks in `tests/test-compat.ss`, covering these fixes and the additional
gaps found while qualifying the full corpus:

- Array lengths above 2^32−1 survive inspection; native construction on 16
  refuses by capability instead of truncating. Rendering preserves them.
- Both old `inrange` index markers and newer range annotations are detected;
  their missing C API support is explicitly reported as not modeled.
- `uinc_wrap`/`udec_wrap` inspection avoids LLVM 16's invalid C enum conversion.
  Their IR exists in 16 even though the C construction API arrived later.
- Metadata value wrappers are identified using their metadata kind, and null
  metadata operands cannot trigger a null native dereference.
- Fast-math eligibility checks the result type for select, phi and call.
- Scalable splats use equivalent syntax accepted by all qualified releases.
- Invoke call-site attributes survive unbuild, native building and rendering.

The native C API limitations documented in `project/llvm-versions.md` remain
explicit. This qualification does not claim feature parity with newer C APIs.

## Environment

- Debian GNU/Linux 13.6 (trixie), x86_64; Linux `6.12.101+deb13-amd64`.
- AMD Ryzen Threadripper PRO 9965WX 24-Cores, 48 logical CPUs.
- Chez Scheme 10.0.0, `scheme`, machine type `ta6le`;
  Debian package `10.0.0+dfsg-5`.
- GNU Make 4.4.1.
- LLVM 16.0.6, 19.1.7, 20.1.8 from `/usr/lib/llvm-{16,19,20}`.
  All selected libraries and C headers report the required exact release.
- Native target `X86`, ELF objects, triple `x86_64-pc-linux-gnu`.
  LLVM 16 reports host CPU `generic`; 19 and 20 report `znver5`.

The adjacent environment files retain the raw observations and package
versions. `llvm{16,19,20}.sexp` was generated with the existing
`../2026-09-12-linux/facts.ss`, passing the major version as its argument.

## Commands and outcomes

Commands ran serially from the repository root in fresh environments:

```sh
env -i PATH=/usr/local/bin:/usr/bin:/bin LC_ALL=C SCHEMELL_LLVM_VERSION=16 make test
```

Repeat that invocation with 19 and 20. Existing compiled library objects were
backed up outside the repository and removed before the source runs.
Then `make examples` built libraries and exercised each release, followed by
another `make test` for each release using those compiled libraries.

| Command | Releases | Result | Logs |
|---|---|---|---|
| `make test` from source | 16 / 19 / 20 | 332 / 362 / 372 passed, zero failed; 15 selection checks each | `test-source-llvm*.log` |
| `make examples` | 16 / 19 / 20 | Pass; 38 scripts invoked per release, four explicitly skip on 16 | `examples-llvm*.log` |
| `make test` with compiled libraries | 16 / 19 / 20 | Same counts and selection checks; all pass | `test-compiled-llvm*.log` |
| `make test-version-cache` | 20 / 19 / 16 / 20 | Bindings compiled under 19; answer 42 in each fresh process | `version-cache.log` |
| `make check-format` | default | Pass | `check-format.log` |
| `scheme --libdirs . --script project/validation/2026-09-12-linux-llvm16/review.ss` | 16 / 19 / 20 | 9 / 8 / 8 passed, zero failed | `review-llvm*.log` |
| `scheme --libdirs . --script project/validation/2026-09-12-linux-llvm16/rebase-integration.ss` | 16 / 19 / 20 | 5 passed per release, zero failed | `integration-llvm*.log` |

Before rebasing, the main suites passed 326 / 357 / 367 checks. The additional
6 / 5 / 5 checks come from upstream's typed-pointer and named-metadata tests.
[rebase-integration.ss](rebase-integration.ss) additionally checks exact native
and renderer round trips for pointer loads/stores, GEPs, indirect calls and
recursive structures. It appends named metadata referencing a function and
Max/Min module flags, then disassembles newly emitted bitcode with the matching
`llvm-dis`. LLVM 16 preserves the typed function signature; 19 and 20 use opaque
pointers. Both metadata flags survive on every release. These five integration
checks are separate from the main suite counts.

The example runs also passed both CLI checks on every release: factorial
returns exit 120, and the 194-byte ELF executable prints `Hello, SchemeLL!`.
The four LLVM 16 example skips are `sll/09-floats.ss`, `sll/11-casts.ss`,
`sll/20-unbuild.ss`, and `aot/01-emit-object.ss`. The Makefile redirects script
stdout, so their skip messages do not appear in the example logs.

The selected-version suites exercise JIT execution, object/assembly emission,
stack maps, ownership checks, selection/refusal behavior and the C-header
coverage oracle. No new macOS, FreeBSD or Metal runtime validation is claimed.

## Matching LLVM 16 corpus

Fetched the unmodified `llvmorg-16.0.6` corpus, commit
`7cbf1a2591520c2491aa35339f227775f4d3adf6`, into `reference/llvm16` using the
commands recorded in `project/RULES.md`. The IR sources there and the installed
`llvm-c`/`llvm/IR` headers were the primary references for the adapter audit.

```sh
env -i PATH=/usr/local/bin:/usr/bin:/bin LC_ALL=C SCHEMELL_LLVM_VERSION=16 scheme --libdirs . --script tests/corpus.ss reference/llvm16/llvm/test
```

The complete rerun after rebasing exits **0**, with no unexplained failures,
native-access errors, canonical IR mismatches or rendering failures:

| Classification | Files |
|---|---:|
| Strict C API round trips | 21,538 |
| Strict text-renderer round trips | 7,324 |
| Builder-folding fixed points | 2 |
| Rejected by LLVM's parser | 596 |
| Explicit not-modeled cases | 2,162 |
| Total | 31,622 |

The harness compares normalized IR within the selected release. Missing
construction APIs can use its existing strict text-renderer tier, provided
the original canonical IR matches exactly; a failed rendering remains a
failed gate. No new lossy normalization was added. Existing unsupported
constructs retain their named buckets. `corpus16-final.log` retains the full
output, including diagnostics from intentionally malformed debug fixtures;
`corpus16-final-buckets.txt` records excluded paths, and the empty
`corpus16-final-failures.txt` records zero unexplained failures.

The original corpus run found 26 silent mismatches, two native-access errors
and unsupported-construction cases not yet routed through the renderer.
Intermediate runs were used to fix the array, GEP, metadata, atomic and splat
paths; the table above describes the final complete rerun.

Trailing spaces and tabs were trimmed in retained logs. The review and rebase
integration sources were formatted and checked with the pinned Schematter.
