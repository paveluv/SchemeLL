#!chezscheme
(import (chezscheme) (prefix (llvm selection) selection:))
[selection:select!
 [selection:make-selection
  (list (cons 'major-version (string->number (car (command-line-arguments)))))]]
(import (prefix (llvm config) config:) (prefix (llvm target) target:))
[pretty-print
 [list
  (cons 'date (date-and-time))
  (cons 'chez (scheme-version))
  (cons 'machine-type (machine-type))
  (cons 'llvm (config:version))
  (cons 'installation config:installation-directory)
  (cons 'shared-object config:shared-object)
  (cons 'shared-object-suffix config:shared-object-suffix)
  (cons 'headers config:header-directory)
  (cons 'headers-validated (begin (config:validate-headers!) #t))
  (cons 'default-triple (target:default-triple))
  (cons 'native-target (target:native-target-name))
  (cons 'native-object-format (target:native-object-format))
  (cons 'llvm-host-cpu (target:host-cpu-name))]]
