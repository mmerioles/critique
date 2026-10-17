APP     := build/Critique.app
# Sign with your Apple Development certificate if you have one, so macOS keeps
# permissions (Screen Recording, Input Monitoring) across rebuilds.
SIGN_ID ?= $(shell security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: app dmg run install clean

# Build the menu bar app into build/Critique.app
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Critique $(APP)/Contents/MacOS/Critique
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_ID)" $(APP)

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
