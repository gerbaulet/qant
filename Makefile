SHELL := /bin/zsh
.DEFAULT_GOAL := qant-help

override DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

override PROJECT := quantified_self.xcodeproj
override SCHEME := quantified_self
override BUNDLE_ID := de.clemensgerbaulet.quantified-self

CONFIGURATION ?= Debug
DERIVED_DATA ?= /tmp/qant-derived
DEVICE_DERIVED_DATA ?= /tmp/qant-device
SIMULATOR_NAME ?= iPhone 17 Pro
SIMULATOR_OS ?= latest
DEVICE ?= Clemens-iPhone2
TEST_TARGET ?= quantified_selfTests

SIMULATOR_DESTINATION = platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=$(SIMULATOR_OS)
DEVICE_APP = $(DEVICE_DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/quantified_self.app
XCODEBUILD = xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)"

.PHONY: \
	qant-help \
	qant-doctor \
	qant-list \
	qant-simulators \
	qant-devices \
	qant-build \
	qant-build-release \
	qant-test \
	qant-test-ui \
	qant-test-all \
	qant-clean \
	qant-build-device \
	qant-install-device \
	qant-launch-device \
	qant-deploy-device

qant-help: ## Show available Qant development commands.
	@awk 'BEGIN { FS = ":.*## " } /^qant-[a-z-]+:.*## / { printf "  %-26s %s\n", $$1, $$2 }' "$(firstword $(MAKEFILE_LIST))"

qant-doctor: ## Verify Xcode and list available simulators and devices.
	xcodebuild -version
	xcrun --find xcodebuild
	xcrun simctl list devices available
	xcrun devicectl list devices

qant-list: ## List the Qant project, targets, configurations, and schemes.
	xcodebuild -project "$(PROJECT)" -list

qant-simulators: ## List currently available simulators.
	xcrun simctl list devices available

qant-devices: ## List physical Apple devices known to Xcode.
	xcrun devicectl list devices

qant-build: ## Build Qant for the iOS Simulator without code signing.
	$(XCODEBUILD) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		build

qant-build-release: ## Build the Release configuration for the iOS Simulator.
	$(MAKE) qant-build CONFIGURATION=Release DERIVED_DATA=/tmp/qant-release

qant-test: ## Run unit tests; override TEST_TARGET for a focused test.
	$(XCODEBUILD) \
		-destination '$(SIMULATOR_DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)" \
		test \
		-only-testing:"$(TEST_TARGET)"

qant-test-ui: ## Run the Qant UI-test target.
	$(MAKE) qant-test TEST_TARGET=quantified_selfUITests

qant-test-all: ## Run all Qant unit and UI tests.
	$(XCODEBUILD) \
		-destination '$(SIMULATOR_DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)" \
		test

qant-clean: ## Clean Qant simulator build products.
	$(XCODEBUILD) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath "$(DERIVED_DATA)" \
		clean

qant-build-device: ## Build a signed Debug app using cached provisioning only.
	$(XCODEBUILD) \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$(DEVICE_DERIVED_DATA)" \
		build

qant-install-device: ## Install the existing device build without deleting app data.
	test -d "$(DEVICE_APP)"
	xcrun devicectl device install app --device "$(DEVICE)" "$(DEVICE_APP)"

qant-launch-device: ## Launch Qant on the selected unlocked iPhone.
	xcrun devicectl device process launch \
		--device "$(DEVICE)" \
		--terminate-existing \
		"$(BUNDLE_ID)"

qant-deploy-device: ## Build, install, and launch Qant on the selected iPhone.
	$(MAKE) qant-build-device
	$(MAKE) qant-install-device
	$(MAKE) qant-launch-device
