# clipvolume — build, run, package, notarize, release.
#
# One-time setup for notarization (needs an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials clipvolume-notary --apple-id you@example.com --team-id HA5AB7JS87

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

.PHONY: project build run stop app dmg notarize release icons clean

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

## Drag-to-Applications disk image (signed, not yet notarized) → build/clipvolume.dmg
dmg: app
	scripts/make_dmg.sh "$(APP)" "$(DMG)"

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

## Publish a GitHub release for the version in project.yml with the notarized dmg attached
release: notarize
	git tag -f "v$(VERSION)"
	git push -f origin "v$(VERSION)"
	gh release create "v$(VERSION)" "$(DMG)" --title "clipvolume $(VERSION)" --generate-notes

## Regenerate AppIcon.icns, favicon, og-image and the dmg background from img/appicon.svg
icons:
	scripts/make_icons.sh
	swift scripts/make_og.swift
	swift scripts/make_dmg_bg.swift $(BUILD)/dmg-background.png 2 && \
		sips -s format tiff -s dpiHeight 144 -s dpiWidth 144 $(BUILD)/dmg-background.png --out Resources/dmg-background.tiff >/dev/null

clean:
	rm -rf "$(BUILD)" "$(PROJECT)"
