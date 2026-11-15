.PHONY: help gen test ui-test test-all security mac mac-zip archive-ios run-mac ios install-ios clean

PROJECT := Letterbox.xcodeproj
DERIVED := build/DerivedData
# Personal settings live in Makefile.local (not in git):
#   DEVICE := <your iPhone's identifier, from `xcrun devicectl list devices`>
#   DEVELOPMENT_TEAM := <your Apple developer team ID>
#   SUPPORT_EMAIL := <support address on the publisher's domain, for reports and Help>
-include Makefile.local
DEVICE ?=
export DEVELOPMENT_TEAM
export SUPPORT_EMAIL
BUNDLE_ID := app.helloletter

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

archive-ios: gen ## App Store build: archive (Release) and upload to App Store Connect / TestFlight. Needs the paid team in Makefile.local
	@test -n "$(DEVELOPMENT_TEAM)" || { echo "Set DEVELOPMENT_TEAM (your paid Apple Developer team) in Makefile.local"; exit 1; }
	xcodebuild -project $(PROJECT) -scheme Letterbox -configuration Release -destination 'generic/platform=iOS' \
		-archivePath build/HelloLetter.xcarchive -allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath build/HelloLetter.xcarchive -exportOptionsPlist Config/ExportOptions.plist \
		-exportPath build/export -allowProvisioningUpdates
	@echo "Uploaded. It appears in App Store Connect → TestFlight after processing (usually 10–30 minutes)."

mac-zip: gen ## Shareable Mac app: Release, universal, ad-hoc signed (no account), zipped in build/dist
	rm -rf build/DerivedData-share build/dist
	xcodebuild -project $(PROJECT) -scheme LetterboxMac -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath build/DerivedData-share ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
		DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO -quiet build
	mkdir -p build/dist
	ditto -c -k --keepParent build/DerivedData-share/Build/Products/Release/HelloLetter.app build/dist/HelloLetter-mac.zip
	@echo "Ready: build/dist/HelloLetter-mac.zip (macOS 15+; recipients allow it in System Settings → Privacy & Security)"

mac: gen ## Build the Mac app
	xcodebuild -project $(PROJECT) -scheme LetterboxMac -configuration Debug -derivedDataPath $(DERIVED) -allowProvisioningUpdates build

run-mac: mac ## Build and open the Mac app
	open $(DERIVED)/Build/Products/Debug/HelloLetter.app

ios: gen ## Build the iPhone app for your device (sign in to Xcode first)
	xcodebuild -project $(PROJECT) -scheme Letterbox -configuration Debug -destination 'id=$(DEVICE)' -derivedDataPath $(DERIVED) -allowProvisioningUpdates build

install-ios: ios ## Build, install and launch on your iPhone
	xcrun devicectl device install app --device $(DEVICE) $(DERIVED)/Build/Products/Debug-iphoneos/Letterbox.app
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE_ID)

clean: ## Remove build output
	rm -rf build Packages/LetterboxKit/.build
