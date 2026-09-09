;;; Run by the pre-commit launcher with scheme --script, so the library path is
;;; set before the helper library is imported.
(library-directories '("schematter"))

(import (prefix (schematter hook) fmt:))

(fmt:format-staged '(".ss" ".sls" ".scm" ".sps" ".sll" ".md" ".markdown"))
