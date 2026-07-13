.PHONY: setup format lint test build clean protocol-test mac-setup mac-format mac-lint mac-test mac-build mac-bundle mac-run ios-setup ios-format ios-lint ios-test ios-integration-test integration-test ios-build sim-build sim-launch sim-recent-sessions-fixture sim-recent-session-detail-fixture sim-rename-session-fixture sim-prompt-queue-fixture sim-long-conversation-fixture sim-long-conversation-from-list-fixture sim-long-conversation-from-session-fixture sim-code-preview-fixture sim-document-browser-fixture sim-connection-connected-fixture sim-connection-failed-fixture phone-build phone-install phone-launch phone-deploy

setup: mac-setup ios-setup

format: mac-format ios-format
	cd Packages/RemoteAgentProtocol && swift format --in-place --recursive Sources Tests Package.swift

lint: mac-lint ios-lint
	cd Packages/RemoteAgentProtocol && swift format lint --recursive Sources Tests Package.swift

test: protocol-test mac-test ios-test

build: mac-build ios-build

clean:
	$(MAKE) -C Apps/MacHost clean
	$(MAKE) -C Apps/iOS clean
	rm -rf Packages/RemoteAgentProtocol/.build

protocol-test:
	swift test --package-path Packages/RemoteAgentProtocol

mac-setup:
	$(MAKE) -C Apps/MacHost setup

mac-format:
	$(MAKE) -C Apps/MacHost format

mac-lint:
	$(MAKE) -C Apps/MacHost lint

mac-test:
	$(MAKE) -C Apps/MacHost test

mac-build:
	$(MAKE) -C Apps/MacHost build

mac-bundle:
	$(MAKE) -C Apps/MacHost bundle

mac-run:
	$(MAKE) -C Apps/MacHost run

ios-setup:
	$(MAKE) -C Apps/iOS setup

ios-format:
	$(MAKE) -C Apps/iOS format

ios-lint:
	$(MAKE) -C Apps/iOS lint

ios-test:
	$(MAKE) -C Apps/iOS test

ios-integration-test:
	$(MAKE) -C Apps/iOS integration-test

integration-test: ios-integration-test

ios-build sim-build:
	$(MAKE) -C Apps/iOS sim-build

sim-launch:
	$(MAKE) -C Apps/iOS sim-launch

sim-recent-sessions-fixture sim-recent-session-detail-fixture sim-rename-session-fixture sim-prompt-queue-fixture sim-long-conversation-fixture sim-long-conversation-from-list-fixture sim-long-conversation-from-session-fixture sim-code-preview-fixture sim-document-browser-fixture sim-connection-connected-fixture sim-connection-failed-fixture:
	$(MAKE) -C Apps/iOS $@

phone-build:
	$(MAKE) -C Apps/iOS phone-build

phone-install:
	$(MAKE) -C Apps/iOS phone-install

phone-launch:
	$(MAKE) -C Apps/iOS phone-launch

phone-deploy:
	$(MAKE) -C Apps/iOS phone-deploy
