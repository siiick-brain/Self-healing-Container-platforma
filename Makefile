.PHONY: up-core up-full down chaos report lint

up-core:
	bash clusters/platform.sh core

up-full:
	bash clusters/platform.sh full

down:
	bash clusters/platform.sh down

chaos report:
	@test -x "scripts/$@.sh" || { echo "$@ is pending implementation"; exit 1; }
	@bash "scripts/$@.sh"

lint:
	bash scripts/lint-prose.sh
	bash scripts/check-provenance.sh
