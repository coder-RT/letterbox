.PHONY: help gen test ui-test test-all security mac run-mac ios install-ios clean

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

security: ## Security checks: secrets (gitleaks), dependencies (osv-scanner), SAST (semgrep), DAST suites. See docs/security-assessment.md
	@command -v gitleaks >/dev/null && command -v osv-scanner >/dev/null && command -v semgrep >/dev/null || \
		{ echo "Install the scanners first: brew install gitleaks osv-scanner semgrep"; exit 1; }
	gitleaks git . --no-banner --redact
	for d in Letterbox Packages/LetterboxKit/Sources Packages/LetterboxKit/Tests LetterboxUITests Config docs; do \
		gitleaks dir $$d --no-banner --redact --gitleaks-ignore-path .gitleaksignore || exit 1; done
	osv-scanner scan source -r Packages/LetterboxKit
	semgrep scan --metrics=off --error --config p/swift --config p/secrets --config p/insecure-transport \
		--exclude build --exclude .build --exclude Letterbox.xcodeproj --quiet .
	cd Packages/LetterboxKit && swift test --filter 'Security'
	@echo "Security checks finished. Known, documented weaknesses show as known issues in the DAST suite."

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
