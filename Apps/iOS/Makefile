PROJECT := RemoteAgentIOS.xcodeproj
SCHEME := RemoteAgentIOS
TEST_SCHEME := RemoteAgentIOS
CONFIGURATION := Debug
DERIVED_DATA := build
APP_NAME := Remote Agent
BUNDLE_ID := com.cseibert.RemoteAgentIOS

SIM_DEVICE_NAME ?= iPhone 17 Pro
SIM_DESTINATION ?= platform=iOS Simulator,name=$(SIM_DEVICE_NAME)
GENERIC_SIM_DESTINATION := generic/platform=iOS Simulator
SIM_FIXTURE ?= recent-sessions

DEVICE_ID ?= 00008150-000E41422E40401C
DEVELOPMENT_TEAM ?= 96NAC4VTEN

.PHONY: setup format lint test integration-test build run clean sim-build sim-launch sim-debug-fixture sim-recent-sessions-fixture sim-recent-session-detail-fixture sim-rename-session-fixture sim-prompt-queue-fixture sim-long-conversation-fixture sim-long-conversation-from-list-fixture sim-long-conversation-from-session-fixture sim-code-preview-fixture sim-document-browser-fixture phone-build phone-install phone-launch phone-deploy

setup:
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME)

format:
	xcrun swift-format format --in-place --recursive RemoteAgentIOS RemoteAgentIOSTests RemoteAgentIOSUITests

lint:
	xcrun swift-format lint --strict --recursive RemoteAgentIOS RemoteAgentIOSTests RemoteAgentIOSUITests
	$(MAKE) sim-build

test:
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(TEST_SCHEME) \
	  -configuration $(CONFIGURATION) \
	  -destination '$(SIM_DESTINATION)' \
	  -derivedDataPath $(DERIVED_DATA) \
	  CODE_SIGNING_ALLOWED=NO \
	  test

integration-test:
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(TEST_SCHEME) \
	  -configuration $(CONFIGURATION) \
	  -destination '$(SIM_DESTINATION)' \
	  -derivedDataPath $(DERIVED_DATA) \
	  CODE_SIGNING_ALLOWED=NO \
	  -only-testing:RemoteAgentIOSUITests \
	  test

build: sim-build

run: sim-launch

sim-build:
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIGURATION) \
	  -destination '$(GENERIC_SIM_DESTINATION)' \
	  -derivedDataPath $(DERIVED_DATA) \
	  CODE_SIGNING_ALLOWED=NO \
	  build

sim-launch: sim-build
	@set -eu; \
	UDID=$$(xcrun simctl list devices available | awk -F '[()]' -v name="$(SIM_DEVICE_NAME)" '{ display=$$1; sub(/^[[:space:]]+/, "", display); sub(/[[:space:]]+$$/, "", display); if (display == name && $$0 !~ /unavailable/) { print $$2; exit } }'); \
	if [ -z "$$UDID" ]; then \
	  echo "No available simulator named $(SIM_DEVICE_NAME)."; \
	  xcrun simctl list devices available; \
	  exit 1; \
	fi; \
	xcrun simctl boot "$$UDID" >/dev/null 2>&1 || true; \
	xcrun simctl bootstatus "$$UDID" -b; \
	open -a Simulator --args -CurrentDeviceUDID "$$UDID"; \
	xcrun simctl install "$$UDID" "$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(APP_NAME).app"; \
	xcrun simctl launch "$$UDID" $(BUNDLE_ID)

sim-debug-fixture: sim-build
	@set -eu; \
	UDID=$$(xcrun simctl list devices available | awk -F '[()]' -v name="$(SIM_DEVICE_NAME)" '{ display=$$1; sub(/^[[:space:]]+/, "", display); sub(/[[:space:]]+$$/, "", display); if (display == name && $$0 !~ /unavailable/) { print $$2; exit } }'); \
	if [ -z "$$UDID" ]; then \
	  echo "No available simulator named $(SIM_DEVICE_NAME)."; \
	  xcrun simctl list devices available; \
	  exit 1; \
	fi; \
	xcrun simctl boot "$$UDID" >/dev/null 2>&1 || true; \
	xcrun simctl bootstatus "$$UDID" -b; \
	open -a Simulator --args -CurrentDeviceUDID "$$UDID"; \
	xcrun simctl install "$$UDID" "$(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(APP_NAME).app"; \
	SIMCTL_CHILD_REMOTE_AGENT_FIXTURE=$(SIM_FIXTURE) xcrun simctl launch --terminate-running-process "$$UDID" $(BUNDLE_ID)

sim-recent-sessions-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=recent-sessions

sim-recent-session-detail-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=recent-session-detail

sim-rename-session-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=rename-session

sim-prompt-queue-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=prompt-queue

sim-long-conversation-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=long-conversation

sim-long-conversation-from-list-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=long-conversation-from-list

sim-long-conversation-from-session-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=long-conversation-from-session

sim-code-preview-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=code-preview

sim-document-browser-fixture:
	$(MAKE) sim-debug-fixture SIM_FIXTURE=document-browser

phone-build:
	xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIGURATION) \
	  -destination 'platform=iOS,id=$(DEVICE_ID)' \
	  -derivedDataPath $(DERIVED_DATA) \
	  CODE_SIGN_STYLE=Automatic \
	  DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) \
	  -allowProvisioningUpdates \
	  -allowProvisioningDeviceRegistration \
	  build

phone-install:
	xcrun devicectl device install app --device $(DEVICE_ID) "$(DERIVED_DATA)/Build/Products/Debug-iphoneos/$(APP_NAME).app"

phone-launch:
	xcrun devicectl device process launch --device $(DEVICE_ID) --terminate-existing $(BUNDLE_ID)

phone-deploy: phone-build phone-install phone-launch

clean:
	rm -rf $(DERIVED_DATA)
