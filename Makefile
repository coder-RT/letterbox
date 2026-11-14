.PHONY: help gen test ui-test test-all mac run-mac ios install-ios clean

PROJECT := Letterbox.xcodeproj
DERIVED := build/DerivedData
# Personal settings live in Makefile.local (not in git):
#   DEVICE := <your iPhone's identifier, from `xcrun devicectl list devices`>
#   DEVELOPMENT_TEAM := <your Apple developer team ID>
-include Makefile.local
DEVICE ?=
export DEVELOPMENT_TEAM
BUNDLE_ID := app.letterbox

help: ## List commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

gen: ## Generate Letterbox.xcodeproj from project.yml (needs: brew install xcodegen)
	xcodegen generate

test: ## Run every LetterboxKit test (no device or radio needed)
	cd Packages/LetterboxKit && swift test

SIMULATOR ?= platform=iOS Simulator,name=iPhone 17,OS=26.5

ui-test: gen ## Run the iPhone UI tests in the simulator (simulated mesh, accessibility audits, screenshots)
	xcodebuild test -project $(PROJECT) -scheme Letterbox -destination '$(SIMULATOR)' -derivedDataPath $(DERIVED) -resultBundlePath build/UITests.xcresult

test-all: test ui-test ## Package tests, then UI tests

mac: gen ## Build the Mac app
	xcodebuild -project $(PROJECT) -scheme LetterboxMac -configuration Debug -derivedDataPath $(DERIVED) -allowProvisioningUpdates build

run-mac: mac ## Build and open the Mac app
	open $(DERIVED)/Build/Products/Debug/Letterbox.app

ios: gen ## Build the iPhone app for your device (sign in to Xcode first)
	xcodebuild -project $(PROJECT) -scheme Letterbox -configuration Debug -destination 'id=$(DEVICE)' -derivedDataPath $(DERIVED) -allowProvisioningUpdates build

install-ios: ios ## Build, install and launch on your iPhone
	xcrun devicectl device install app --device $(DEVICE) $(DERIVED)/Build/Products/Debug-iphoneos/Letterbox.app
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE_ID)

clean: ## Remove build output
	rm -rf build Packages/LetterboxKit/.build
