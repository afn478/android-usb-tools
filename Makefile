APP := build/Tether.app
DMG := build/Tether.dmg
SIGN_IDENTITY ?= Apple Development
ARCH := $(shell uname -m)

CFLAGS := -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0
FRAMEWORKS := -framework Foundation -framework IOKit -framework IOUSBHost -framework SystemConfiguration
SIGN := codesign --force --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)"

all: $(APP)

build/rndis-tether: src/main.m
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ $<

build/Tether: app/Tether.swift
	@mkdir -p build
	swiftc -O -parse-as-library -target $(ARCH)-apple-macos13.0 -o $@ $<

build/AppIcon.icns: tools/make-icon.swift
	@mkdir -p build/AppIcon.iconset
	swift tools/make-icon.swift build/icon-1024.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns -o $@ build/AppIcon.iconset

$(APP): build/rndis-tether build/Tether build/AppIcon.icns app/Info.plist launchd/io.github.afn478.rndis-tether.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Resources $@/Contents/Library/LaunchDaemons
	cp app/Info.plist $@/Contents/
	cp build/AppIcon.icns $@/Contents/Resources/
	cp launchd/io.github.afn478.rndis-tether.plist $@/Contents/Library/LaunchDaemons/
	cp build/Tether build/rndis-tether $@/Contents/MacOS/
	$(SIGN) --identifier io.github.afn478.rndis-tether $@/Contents/MacOS/rndis-tether
	$(SIGN) $@

# Drag-to-install disk image.
dmg: $(DMG)

$(DMG): $(APP) tools/make-dmg.sh tools/make-dmg-background.swift
	tools/make-dmg.sh $(APP) build/AppIcon.icns $@ "$(SIGN_IDENTITY)"

# Developer shortcut: replace the installed copy and relaunch it.
install: $(APP)
	-pkill -x Tether
	rm -rf /Applications/Tether.app
	cp -R $(APP) /Applications/
	open /Applications/Tether.app

clean:
	rm -rf build

.PHONY: all dmg install clean
