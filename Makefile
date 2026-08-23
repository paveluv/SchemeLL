CHEZ ?= scheme
LIBDIRS = .

.PHONY: test repl build corpus format clean examples

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
examples:
	@for f in examples/sll/*.ss examples/llvm/*.ss examples/aot/*.ss; do \
	  echo "== $$f"; $(CHEZ) --libdirs $(LIBDIRS) --script $$f >/dev/null || exit 1; \
	done
	@$(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss --run examples/aot/fact.sll; \
	  test $$? -eq 120 || exit 1
	@$(CHEZ) --libdirs $(LIBDIRS) --script tools/sllc.ss --opt O2 --exe examples/aot/hello.sll && \
	  ./examples/aot/hello && rm -f examples/aot/hello
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
