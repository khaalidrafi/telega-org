EMACS ?= emacs

# The package loads without telega: its public API is declared, not
# required, and the tests stub it.  No telega on `load-path' needed, and
# no -Q here either, so a distribution's site-lisp is still found.
LOAD = -L .

SRCS = telega-org.el

all: compile

# A warning against telega's declared API is a warning that upstream
# renamed something, and is worth seeing.
compile:
	$(EMACS) --batch $(LOAD) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRCS)

test:
	$(EMACS) --batch $(LOAD) -l test -f ert-run-tests-batch-and-exit

clean:
	rm -f $(SRCS:.el=.elc) test.elc

.PHONY: all compile test clean