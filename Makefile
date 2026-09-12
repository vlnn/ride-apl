EMACS ?= emacs
TESTS := $(wildcard test/*-test.el)
LOAD_TESTS := $(foreach f,$(TESTS),-l $(f))

test:
	$(EMACS) -Q --batch -L . -L test \
	  -l ert $(LOAD_TESTS) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile *.el
	rm -f *.elc

.PHONY: test compile

lint:
	emacs -Q --batch -L . --eval '(setq checkdoc-autofix-flag (quote never))' \
	  --eval '(dolist (f (directory-files "." nil "\\.el$$")) (checkdoc-file f))' 2>&1 | grep -v '^Loading' || true
	@if [ -d /tmp/package-lint ]; then \
	  emacs -Q --batch -L /tmp/package-lint -L . --eval '(require (quote package))' \
	    --eval '(setq package-lint-main-file "ride-apl.el")' \
	    -l package-lint -f package-lint-batch-and-exit *.el || true; \
	else echo "package-lint not present (clone https://github.com/purcell/package-lint to /tmp)"; fi

.PHONY: lint
