PYTHON ?= python3
COREX_ROOT ?= /usr/local/corex
.PHONY: all test check clean
all:
	$(PYTHON) build_corex.py --corex-root "$(COREX_ROOT)"
test:
	$(PYTHON) -m unittest discover -s tests -v
check:
	$(PYTHON) lhctl.py check
clean:
	rm -f liblitehost.so liblitehost.build.json liblitehost.build.log liblitehost.exports.txt liblitehost.wrappers.cpp
