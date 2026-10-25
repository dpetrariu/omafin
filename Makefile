# Omafin — build the backend and install the plugin for development.
CARGO ?= cargo
BIN := bin/omafin

.PHONY: build install link test test-rust test-backend test-ui test-fetch lint clean

build:
	$(CARGO) build --release --locked

# The plugin runs bin/omafin from its own folder.
install: build
	mkdir -p bin
	install -m 755 target/release/omafin $(BIN)

# Point Omarchy at this checkout and enable the plugin (bar widget, service, window).
link: install
	./scripts/link-plugin.sh

test: test-rust test-backend test-ui test-fetch lint

test-rust:
	$(CARGO) test --locked

# The real backend against tests/mock_jellyfin.py: sign-in, library, marks,
# playback negotiation, the media proxy, reports and the mpv handoff.
test-backend:
	$(CARGO) build --locked
	python3 tests/backend_e2e.py target/debug/omafin

# Drives the real window off-screen (QT_QPA_PLATFORM=offscreen) against the
# seeded mock. Set OMAFIN_UI_SHOTS=/some/dir to keep the screenshots.
test-ui:
	$(CARGO) build --locked
	python3 tests/ui_e2e.py target/debug/omafin

# A plugin without a backend downloads and verifies one from a local stand-in release.
test-fetch:
	$(CARGO) build --locked
	python3 tests/fetch_e2e.py target/debug/omafin

lint:
	@for f in $$(find ui -name '*.qml'); do /usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml $$f >/dev/null 2>&1 || true; done
	@node --version >/dev/null 2>&1 && node tests/ui_logic.js || echo "node not found; skipping UI logic tests"

clean:
	rm -rf target bin
