CONFIGURATION ?= debug
APP := build/Remote Agent.app

.PHONY: setup format lint test build icons bundle run clean

setup:
	swift package resolve

format:
	swift format --in-place --recursive Sources Tests Package.swift

lint:
	swift format lint --recursive Sources Tests Package.swift

test:
	swift test

build:
	swift build -c $(CONFIGURATION)

icons:
	sh scripts/generate_icon.sh

bundle: icons
	sh scripts/package_app.sh $(CONFIGURATION)

run: bundle
	@if pgrep -x RemoteAgent >/dev/null; then osascript -e 'tell application "Remote Agent" to quit'; sleep 1; fi
	open "$(APP)"

clean:
	swift package clean
	rm -rf build
