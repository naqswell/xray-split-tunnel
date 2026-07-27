PYTHON ?= python3
BASH ?= /bin/bash

.PHONY: check test test-python test-shell test-plist release

check: test

test:
	PYTHON="$(PYTHON)" "$(BASH)" tests/run.sh

test-python:
	PYTHONDONTWRITEBYTECODE=1 "$(PYTHON)" -m unittest discover -s tests -p 'test_*.py' -v

test-shell:
	@for script in install.sh uninstall.sh bin/xst lib/common.sh tests/run.sh; do \
		"$(BASH)" -n "$$script" || exit; \
	done

test-plist:
	"$(PYTHON)" -c 'import plistlib; plistlib.load(open("templates/launchagent.plist.template", "rb"))'

release:
	"$(BASH)" scripts/release.sh
