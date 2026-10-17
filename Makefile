APP     := build/UXFlow.app
# Sign with your Apple Development certificate if you have one, so macOS keeps
# permissions (Screen Recording, Input Monitoring) across rebuilds.
SIGN_ID ?= $(shell security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: app run install clean

# Build the menu bar app into build/UXFlow.app
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/UXFlow $(APP)/Contents/MacOS/UXFlow
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN_ID)" $(APP)

# Build and launch
run: app
	open $(APP)

# Copy to /Applications and launch
install: app
	rm -rf /Applications/UXFlow.app
	cp -R $(APP) /Applications/UXFlow.app
	open /Applications/UXFlow.app

clean:
	rm -rf .build build
