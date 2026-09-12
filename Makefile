# clipvolume — build, run, package, notarize, release.
#
# Release via Xcode (the usual way):
#   make project → open clipvolume.xcodeproj → Product ▸ Archive → Distribute App ▸ Direct Distribution
#   (Xcode notarizes and staples) → Export → then:
#   make dmg APP="/path/to/exported/clipvolume.app"     # signed dmg around the notarized app
#   make publish                                        # tag v<version> + GitHub release with the dmg
#
# Release from the command line instead (needs a notarytool keychain profile once):
#   xcrun notarytool store-credentials clipvolume-notary --apple-id you@example.com --team-id HA5AB7JS87
#   make release

TEAM_ID   := HA5AB7JS87
PROFILE   ?= clipvolume-notary
PRODUCT   := clipvolume
SCHEME    := clipvolume
PROJECT   := $(SCHEME).xcodeproj
VERSION   := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)

BUILD     := build
DD        := $(BUILD)/DerivedData
APP_DEBUG := $(DD)/Build/Products/Debug/$(PRODUCT).app
ARCHIVE   := $(BUILD)/$(SCHEME).xcarchive
EXPORT    := $(BUILD)/export
APP       := $(EXPORT)/$(PRODUCT).app
ZIP       := $(BUILD)/$(PRODUCT).zip
DMG       := $(BUILD)/$(PRODUCT).dmg
IDENTITY  := Developer ID Application

.PHONY: project build run stop app dmg notarize release publish icons clean

## Generate the Xcode project from project.yml
project:
	xcodegen generate

## Debug build (signed with Developer ID so TCC permissions stick between builds)
build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DD) build | grep -E "error|warning: |BUILD" || true
	@test -d "$(APP_DEBUG)"

## Build and (re)launch the debug app
run: build stop
	open "$(APP_DEBUG)"

stop:
	-pkill -x "$(PRODUCT)" 2>/dev/null

## Release archive + Developer ID export → build/export/clipvolume.app
app: project
	rm -rf "$(ARCHIVE)" "$(EXPORT)"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-archivePath "$(ARCHIVE)" archive | grep -E "error|warning: |ARCHIVE" || true
	xcodebuild -exportArchive -archivePath "$(ARCHIVE)" \
		-exportOptionsPlist ExportOptions.plist -exportPath "$(EXPORT)" | grep -E "error|EXPORT" || true
	@test -d "$(APP)"

## Drag-to-Applications disk image → build/clipvolume.dmg
## Pass APP=/path/to/clipvolume.app to wrap an app you exported (and notarized) from Xcode;
## otherwise a fresh Release build is used (signed, not notarized).
ifeq ($(origin APP), command line)
dmg:
else
dmg: app
endif
	@test -d "$(APP)" || { echo "error: $(APP) not found"; exit 1; }
	scripts/make_dmg.sh "$(APP)" "$(DMG)"
	codesign --force --sign "$(IDENTITY)" "$(DMG)"
	@stapler validate "$(APP)" >/dev/null 2>&1 && echo "→ $(DMG) (app inside is notarized + stapled)" \
		|| echo "→ $(DMG) (note: app inside is NOT notarized — use Xcode's Direct Distribution or 'make notarize')"

## Publish a GitHub release for the version in project.yml with build/clipvolume.dmg attached
publish:
	@test -f "$(DMG)" || { echo "error: $(DMG) not found — run 'make dmg' first"; exit 1; }
	git tag -f "v$(VERSION)"
	git push -f origin "v$(VERSION)"
	gh release create "v$(VERSION)" "$(DMG)" --title "clipvolume $(VERSION)" --generate-notes

## Notarize the app, staple it, rebuild the dmg around it, notarize + staple the dmg
notarize: app
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	xcrun notarytool submit "$(ZIP)" --keychain-profile $(PROFILE) --wait
	xcrun stapler staple "$(APP)"
	scripts/make_dmg.sh "$(APP)" "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile $(PROFILE) --wait
	xcrun stapler staple "$(DMG)"
	spctl -a -vv -t open --context context:primary-signature "$(DMG)"
	@echo "→ $(DMG) (notarized)"

## Command-line equivalent of the Xcode route: notarize, then publish
release: notarize publish

## Regenerate AppIcon.icns, favicon, og-image and the dmg background from img/appicon.svg
icons:
	scripts/make_icons.sh
	swift scripts/make_og.swift
	swift scripts/make_dmg_bg.swift $(BUILD)/dmg-background.png 2 && \
		sips -s format tiff -s dpiHeight 144 -s dpiWidth 144 $(BUILD)/dmg-background.png --out Resources/dmg-background.tiff >/dev/null

clean:
	rm -rf "$(BUILD)" "$(PROJECT)"
