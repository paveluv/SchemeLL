;;; Test entry point: scheme --libdirs . --script tests/run.ss
(load "host/bootstrap.ss")
(import (chezscheme) (prefix (tests harness) t:))

(load "tests/test-datalayout.ss")
(load "tests/test-ir.ss")
(load "tests/test-jit.ss")
(load "tests/test-object.ss")
(load "tests/test-sll.ss")
(load "tests/test-asm.ss")
(load "tests/test-version.ss")
(load "tests/test-compat.ss")
(load "tests/test-coverage.ss")

(t:summary-and-exit)
