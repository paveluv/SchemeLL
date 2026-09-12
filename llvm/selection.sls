;;; Pure installation selection. No getenv, filesystem discovery, or FFI.
[library
 (llvm selection)
 [export
  make-selection
  selection?
  selection-ref
  select!
  selected?
  sealed?
  setting]
 (import (chezscheme))
 (define (path? x) (or (not x) (and (string? x) (> (string-length x) 0))))
 [define
  schema
  [list
   (list 'major-version 19 (lambda (x) (and (memv x '(19 20)) #t)))
   (list 'prefix #f path?)
   (list 'shared-object #f path?)
   (list 'header-directory #f path?)
   (list 'version-header #f path?)]]
 (define-record-type (selection %make-selection selection?) (fields entries))
 (define (copy-value x) (if (string? x) (string-copy x) x))
 [define
  (make-selection overrides)
  [unless
   (list? overrides)
   (error 'make-selection "expected an alist" overrides)]
  [let
   ((seen '()))
   [for-each
    [lambda
     (row)
     [unless
      (and (pair? row) (assq (car row) schema))
      (error 'make-selection "unknown LLVM selection key" row)]
     [when
      (memq (car row) seen)
      (error 'make-selection "duplicate LLVM selection key" (car row))]
     (set! seen (cons (car row) seen))
     [unless
      ((caddr (assq (car row) schema)) (cdr row))
      (error 'make-selection "invalid LLVM selection value" row)]]
    overrides]]
  [%make-selection
   [map
    [lambda
     (entry)
     [let
      ((row (assq (car entry) overrides)))
      (cons (car entry) (copy-value (if row (cdr row) (cadr entry))))]]
    schema]]]
 [define
  (selection-ref profile key)
  [unless
   (selection? profile)
   (error 'selection-ref "expected selection" profile)]
  [let
   ((row (assq key (selection-entries profile))))
   (unless row (error 'selection-ref "unknown LLVM selection key" key))
   (copy-value (cdr row))]]
 (define selected-profile (make-selection '()))
 (define installed? #f)
 (define frozen? #f)
 (define (selected?) installed?)
 (define (sealed?) frozen?)
 [define
  (select! new)
  (unless (selection? new) (error 'select! "expected selection" new))
  [when
   [and
    frozen?
    (not (equal? (selection-entries selected-profile) (selection-entries new)))]
   [error
    'select!
    "LLVM selection is sealed; select before importing LLVM bindings"]]
  (set! selected-profile new)
  (set! installed? #t)]
 [define
  (setting key)
  [let
   ((value (selection-ref selected-profile key)))
   (set! installed? #t)
   (set! frozen? #t)
   value]]]
