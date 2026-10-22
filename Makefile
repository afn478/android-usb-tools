NAME := Android USB Tools
EXE := AndroidUSBTools
HELPER_PLIST := io.github.afn478.AndroidUSBTools.tethering.plist
SIGN_IDENTITY ?= Apple Development
ARCH := $(shell uname -m)

# The bundle name has spaces, which make can't use as a target; a stamp file
# stands in for the bundle.
APP = build/$(NAME).app
APP_STAMP := build/.app-stamp
DMG := build/AndroidUSBTools.dmg

CFLAGS := -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0
FRAMEWORKS := -framework Foundation -framework IOKit -framework IOUSBHost -framework SystemConfiguration
SIGN := codesign --force --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)"

all: $(APP_STAMP)

build/rndis-tether: src/main.m
	@mkdir -p build
	clang $(CFLAGS) $(FRAMEWORKS) -o $@ $<

build/$(EXE): app/AndroidUSBTools.swift app/FileAccess.swift app/PhoneWatcher.swift
	@mkdir -p build
	swiftc -O -parse-as-library -target $(ARCH)-apple-macos26.0 -o $@ $^

build/AppIcon.icns: tools/make-icon.swift
	@mkdir -p build/AppIcon.iconset
	swift tools/make-icon.swift build/icon-1024.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns -o $@ build/AppIcon.iconset

$(APP_STAMP): build/rndis-tether build/mtpfs mtp/mtpfs.entitlements build/$(EXE) build/AppIcon.icns app/Info.plist launchd/$(HELPER_PLIST)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Library/LaunchDaemons"
	cp app/Info.plist "$(APP)/Contents/"
	cp build/AppIcon.icns "$(APP)/Contents/Resources/"
	cp launchd/$(HELPER_PLIST) "$(APP)/Contents/Library/LaunchDaemons/"
	cp build/$(EXE) build/rndis-tether build/mtpfs "$(APP)/Contents/MacOS/"
	strip -S -x "$(APP)/Contents/MacOS/$(EXE)" "$(APP)/Contents/MacOS/rndis-tether" "$(APP)/Contents/MacOS/mtpfs"
	$(SIGN) --identifier io.github.afn478.AndroidUSBTools.tethering "$(APP)/Contents/MacOS/rndis-tether"
	$(SIGN) --identifier io.github.afn478.AndroidUSBTools.mtpfs --entitlements mtp/mtpfs.entitlements "$(APP)/Contents/MacOS/mtpfs"
	$(SIGN) "$(APP)"
	touch $@

# Drag-to-install disk image.
dmg: $(DMG)

$(DMG): $(APP_STAMP) tools/make-dmg.sh tools/make-dmg-background.swift
	tools/make-dmg.sh "$(APP)" build/AppIcon.icns $@ "$(SIGN_IDENTITY)"

# Developer shortcut: replace the installed copy and relaunch it.
install: $(APP_STAMP)
	-pkill -x $(EXE)
	rm -rf "/Applications/$(NAME).app"
	cp -R "$(APP)" /Applications/
	open "/Applications/$(NAME).app"

# File access: mtpfs mounts a phone in File transfer mode through macFUSE
# (building and running it needs macFUSE: brew install --cask macfuse);
# mtp-probe lists and checksums files for debugging.
MTP_CFLAGS := -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=26.0
MTP_FRAMEWORKS := -framework Foundation -framework IOKit -framework IOUSBHost

build/mtp-probe: mtp/MTPDevice.m mtp/MTPDevice.h mtp/probe.m
	@mkdir -p build
	clang $(MTP_CFLAGS) $(MTP_FRAMEWORKS) -o $@ mtp/MTPDevice.m mtp/probe.m

build/mtpfs: mtp/MTPDevice.m mtp/MTPDevice.h mtp/mtpfs.m
	@mkdir -p build
	clang $(MTP_CFLAGS) -I/usr/local/include/fuse3 $(MTP_FRAMEWORKS) -L/usr/local/lib -lfuse3 \
		-Wl,-rpath,/usr/local/lib -o $@ mtp/MTPDevice.m mtp/mtpfs.m

mtp: build/mtp-probe build/mtpfs

clean:
	rm -rf build

.PHONY: all dmg install clean mtp
