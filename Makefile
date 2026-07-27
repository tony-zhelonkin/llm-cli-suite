.PHONY: test verify install golden help

help:
	@echo "make test     - run the offline test suite (what CI runs)"
	@echo "make verify   - on-box drift check (running system vs repo)"
	@echo "make install  - symlink tools into ~/.local/bin"
	@echo "make golden   - regenerate the renderer golden fixture"

test:
	@bash tests/run.sh

verify:
	@bash tests/verify-live.sh

install:
	@./install.sh

golden:
	@bash tests/regen-golden.sh
