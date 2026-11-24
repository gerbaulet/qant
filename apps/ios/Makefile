SHELL := /bin/zsh
.DEFAULT_GOAL := help

override DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

override PROJECT := quantified_self.xcodeproj
override SCHEME := Quant
override BUNDLE_ID := de.clemensgerbaulet.quantified-self

BREW ?= brew
BREW_PREFIX ?= $(shell $(BREW) --prefix 2>/dev/null)
BREW_BUNDLE ?= $(BREW_PREFIX)/opt/ruby/bin/bundle

CONFIGURATION ?= Debug
DERIVED_DATA ?= /tmp/quant-derived
DEVICE_DERIVED_DATA ?= /tmp/quant-device
SIMULATOR_NAME ?= iPhone 17
SIMULATOR_OS ?= latest
DEVICE ?= Clemens-iPhone2
TEST_TARGET ?= QuantTests

POSITIONAL_DEVICE :=
ifeq ($(firstword $(MAKECMDGOALS)),deploy-device)
POSITIONAL_DEVICE := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
endif

ifneq ($(strip $(POSITIONAL_DEVICE)),)
ifeq ($(origin DEVICE),command line)
$(error Pass the device either as a quoted argument or with DEVICE=..., not both)
endif
override DEVICE := $(POSITIONAL_DEVICE)

# Make treats the quoted device name as another goal. Accept that exact goal
# after deploy-device so names containing spaces can be used positionally.
.DEFAULT:
	@actual_target="$@"; \
	if [[ -n "$%" ]]; then actual_target="$@($%)"; fi; \
	test "$$actual_target" = "$(POSITIONAL_DEVICE)" || { echo "Unknown target: $$actual_target" >&2; exit 2; }
endif

SIMULATOR_DESTINATION = platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=$(SIMULATOR_OS)
DEVICE_APP = $(DEVICE_DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos/Quant.app
XCODEBUILD = xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)"

.PHONY: \
	help \
	doctor \
	list \
	simulators \
	devices \
	build \
	build-release \
	test \
	test-ui \
	test-all \
	clean \
	build-device \
	install-device \
	launch-device \
	deploy-device \
	testflight-setup \
	testflight

help: ## Show available Quant development commands.
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-26s %s\n", $$1, $$2 }' "$(firstword $(MAKEFILE_LIST))"

doctor: ## Verify Xcode and list available simulators and devices.
	xcodebuild -version
	xcrun --find xcodebuild
	xcrun simctl list devices available
	xcrun devicectl list devices

list: ## List the Quant project, targets, configurations, and schemes.
	xcodebuild -project "$(PROJECT)" -list

simulators: ## List currently available simulators.
	xcrun simctl list devices available

devices: ## List physical Apple devices known to Xcode.
	xcrun devicectl list devices

build: ## Build Quant for the iOS Simulator without code signing.
	$(XCODEBUILD) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath "$(DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		build

build-release: ## Build the Release configuration for the iOS Simulator.
	$(MAKE) build CONFIGURATION=Release DERIVED_DATA=/tmp/release

test: ## Run unit tests; override TEST_TARGET for a focused test.
	$(XCODEBUILD) \
		-destination '$(SIMULATOR_DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)" \
		test \
		-only-testing:"$(TEST_TARGET)"

test-ui: ## Run the Quant UI-test target.
	$(MAKE) test TEST_TARGET=QuantUITests

test-all: ## Run all Quant unit and UI tests.
	$(XCODEBUILD) \
		-destination '$(SIMULATOR_DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)" \
		test

clean: ## Clean Quant simulator build products.
	$(XCODEBUILD) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath "$(DERIVED_DATA)" \
		clean

build-device: ## Build a signed Debug app using cached provisioning only.
	$(XCODEBUILD) \
		-destination 'generic/platform=iOS' \
		-derivedDataPath "$(DEVICE_DERIVED_DATA)" \
		build

install-device: ## Install the existing device build without deleting app data.
	test -d "$(DEVICE_APP)"
	xcrun devicectl device install app --device "$(DEVICE)" "$(DEVICE_APP)"

launch-device: ## Launch Quant on the selected unlocked iPhone.
	xcrun devicectl device process launch \
		--device "$(DEVICE)" \
		--terminate-existing \
		"$(BUNDLE_ID)"

deploy-device: ## Build, install, and launch Quant; accepts a quoted device name.
	$(MAKE) build-device DEVICE="$(DEVICE)"
	$(MAKE) install-device DEVICE="$(DEVICE)"
	$(MAKE) launch-device DEVICE="$(DEVICE)"

testflight-setup: ## Install the pinned local Fastlane toolchain.
	command -v "$(BREW)" >/dev/null
	$(BREW) list --versions ruby >/dev/null 2>&1 || $(BREW) install ruby
	test -x "$(BREW_BUNDLE)"
	"$(BREW_BUNDLE)" config set --local path vendor/bundle
	"$(BREW_BUNDLE)" install

testflight: ## Prompt, confirm, upload, and distribute the next TestFlight build.
	test -f fastlane/.env || { echo "Missing fastlane/.env; see TESTFLIGHT.md" >&2; exit 2; }
	test -x "$(BREW_BUNDLE)" || { echo "Missing Homebrew Ruby; run make testflight-setup" >&2; exit 2; }
	"$(BREW_BUNDLE)" check >/dev/null || { echo "Missing Fastlane gems; run make testflight-setup" >&2; exit 2; }
	FASTLANE_OPT_OUT_USAGE=1 FASTLANE_SKIP_UPDATE_CHECK=1 \
		LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
		"$(BREW_BUNDLE)" exec fastlane ios deploy_testflight
