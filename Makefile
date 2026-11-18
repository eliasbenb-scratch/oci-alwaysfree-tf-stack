.RECIPEPREFIX := >

TERRAFORM ?= terraform
PYTHON ?= python3
BATS ?= bats
SHELLCHECK ?= shellcheck

.PHONY: check format fmt validate test lint

check: fmt validate test lint

format:
> $(TERRAFORM) fmt -recursive

fmt:
> $(TERRAFORM) fmt -check -recursive

validate:
> $(TERRAFORM) validate

test:
> $(TERRAFORM) test -no-color
> PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -v
> $(BATS) tests/preflight.bats

lint:
> $(SHELLCHECK) scripts/preflight.sh scripts/bootstrap.sh
> bash -n scripts/preflight.sh
> bash -n scripts/bootstrap.sh
