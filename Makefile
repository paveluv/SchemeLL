CHEZ ?= scheme
LIBDIRS = .

.PHONY: test repl build corpus format clean examples reference

test:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/run.ss

repl:
	$(CHEZ) --libdirs $(LIBDIRS)

# Level-3 coverage: round-trip LLVM's own test corpus through sll
# (needs reference/llvm-project, see project/RULES.md)
CORPUS_DIR = reference/llvm-project/llvm/test
corpus:
	$(CHEZ) --libdirs $(LIBDIRS) --script tests/corpus.ss $(CORPUS_DIR)

# Format all tracked Scheme sources in place (prints the files it changed)
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

examples:
	@for f in examples/sll/*.ss examples/llvm/*.ss examples/aot/*.ss; do \
	  echo "== $$f"; $(CHEZ) --libdirs $(LIBDIRS) --script $$f >/dev/null || exit 1; \
	done
	@$(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss --run examples/aot/fact.sll; \
	  test $$? -eq 120 || exit 1
	@$(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss --opt O2 --exe examples/aot/hello-linux-x86.sll && \
	  ./examples/aot/hello-linux-x86 && rm -f examples/aot/hello-linux-x86
	@echo "examples ok"

format:
	~/.e/tools/scheme-format -i $$(git ls-files '*.sls' '*.ss')

# Compile libraries to Chez object files (llvm/*.so -- not ELF, gitignored)
build:
	echo '(compile-imported-libraries #t)(import (prefix (sll) sll:) (prefix (llvm target) target:))' | $(CHEZ) -q --libdirs $(LIBDIRS)

clean:
	find llvm sll tests -name '*.so' -delete 2>/dev/null; \
	find llvm sll tests -name '*.wpo' -delete 2>/dev/null; \
	rm -rf tests/tmp
