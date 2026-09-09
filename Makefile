# Chez's binary is `scheme` on most systems, `chez-scheme` on FreeBSD
# (and some Linux distros); override with `make CHEZ=...`. The !=
# shell-assignment works in both BSD make and GNU make (>= 4.0).
CHEZ_DETECTED != command -v scheme >/dev/null 2>&1 && echo scheme || echo chez-scheme
CHEZ ?= $(CHEZ_DETECTED)
LIBDIRS = .
SCHEME_SOURCES = '*.sls' '*.ss' '*.scm' '*.sps' '*.sll'

.PHONY: test repl build corpus format check-format clean examples reference

test:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/run.ss

repl:
	$(CHEZ) --libdirs $(LIBDIRS)

# Level-3 coverage: round-trip LLVM's own test corpus through sll
# (needs reference/llvm-project, see project/RULES.md)
CORPUS_DIR = reference/llvm-project/llvm/test
corpus:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/corpus.ss $(CORPUS_DIR)

# Populate reference/ with what the tests need: LLVM's regression
# corpus (for `make corpus`), pinned to the LLVM version the bindings
# target. Idempotent. See project/RULES.md ("The reference/ directory")
# for the full catalogue, including optional extras like llvm/docs.
LLVM_TAG = llvmorg-19.1.7
reference:
	@test -d reference/llvm-project || \
	  git clone --depth 1 --branch $(LLVM_TAG) --filter=blob:none \
	    --sparse https://github.com/llvm/llvm-project.git \
	    reference/llvm-project
	@cd reference/llvm-project && git sparse-checkout add llvm/test
	@echo "reference ready: $$(find reference/llvm-project/llvm/test \
	  -name '*.ll' | wc -l) .ll files"

# depends on build: each example is its own Chez process, and without
# compiled library objects every one of the 37 re-compiles the whole
# stack in memory (~35s total); with them the run takes ~5s.
examples: build
	@for f in examples/sll/*.ss examples/llvm/*.ss examples/aot/*.ss; do \
	  echo "== $$f"; $(CHEZ) --libdirs $(LIBDIRS) --script $$f >/dev/null || exit 1; \
	done
	@$(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss --run examples/aot/fact.sll; \
	  test $$? -eq 120 || exit 1
	@$(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss --opt O2 --exe examples/aot/hello-metaprog.sll && \
	  ./examples/aot/hello-metaprog && rm -f examples/aot/hello-metaprog
	@echo "examples ok"

schematter/schematter.sps:
	@echo "Schematter is missing; run: git submodule update --init --recursive" >&2
	@exit 1

# Format all tracked Scheme sources, including .sll (prints changed paths).
format: schematter/schematter.sps
	git ls-files -z -- $(SCHEME_SOURCES) | \
	  xargs -0 $(CHEZ) --script schematter/schematter.sps -i --

check-format: schematter/schematter.sps
	git ls-files -z -- $(SCHEME_SOURCES) | \
	  xargs -0 $(CHEZ) --script schematter/schematter.sps --check --

# Compile every library to Chez object files (*.so -- Chez objects,
# not ELF; gitignored). Any later run with --libdirs reuses them; the
# ./sllc wrapper also compiles on demand.
build:
	echo '(compile-imported-libraries #t)(import (prefix (sll) sll:) (prefix (sll render) render:) (prefix (sll asm) asm:) (prefix (llvm target) target:) (prefix (tests normalize) n:))' | $(CHEZ) -q --libdirs $(LIBDIRS)

clean:
	find llvm sll tests -name '*.so' -delete 2>/dev/null; \
	find llvm sll tests -name '*.wpo' -delete 2>/dev/null; \
	rm -rf tests/tmp
