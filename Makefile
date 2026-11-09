APP     := build/Critique.app
# Sign with your Apple Development certificate if you have one, so macOS keeps
# permissions (Screen Recording, Input Monitoring) across rebuilds.
SIGN_ID ?= $(shell security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif
# A real identity gets the hardened runtime, a trusted timestamp and the
# entitlements, which notarization requires. Ad-hoc ("-") can't have those.
ifeq ($(SIGN_ID),-)
SIGN_FLAGS :=
else
SIGN_FLAGS := --options runtime --timestamp --entitlements Resources/Critique.entitlements
endif

# CI sets these to stamp the release version into the app; local builds keep Info.plist's.
VERSION ?=
BUILD ?=

.PHONY: app dmg run install clean helper test

# Rebuild the phone helper (Quick Settings tile) into Resources/critique-helper.apk
helper:
	./android-helper/build.sh

# Build the menu bar app into build/Critique.app
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Critique $(APP)/Contents/MacOS/Critique
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	$(if $(VERSION),plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP)/Contents/Info.plist)
	$(if $(BUILD),plutil -replace CFBundleVersion -string "$(BUILD)" $(APP)/Contents/Info.plist)
	mkdir -p $(APP)/Contents/Resources
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp Resources/critique-helper.apk $(APP)/Contents/Resources/critique-helper.apk
	cp -R browser-extension $(APP)/Contents/Resources/browser-extension
	codesign --force --sign "$(SIGN_ID)" $(SIGN_FLAGS) $(APP)

# Build the app and package it as a drag-to-Applications DMG
dmg: app
	./scripts/make-dmg.sh

# Build and launch
run: app
	open $(APP)

# Copy to /Applications and launch
install: app
	rm -rf /Applications/Critique.app
	cp -R $(APP) /Applications/Critique.app
	open /Applications/Critique.app

clean:
	rm -rf .build build

# Run the unit tests
test:
	swift test
