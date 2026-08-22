;;; Test entry point: scheme --libdirs . --script tests/run.ss
(import (chezscheme) (tests harness))

(load "tests/test-ir.ss")
(load "tests/test-jit.ss")
(load "tests/test-object.ss")

(test-summary-and-exit)
