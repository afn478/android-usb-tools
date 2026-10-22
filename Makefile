APP := build/Tether.app
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

$(APP): build/rndis-tether build/Tether app/Info.plist launchd/io.github.afn478.rndis-tether.plist
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Library/LaunchDaemons
	cp app/Info.plist $@/Contents/
	cp launchd/io.github.afn478.rndis-tether.plist $@/Contents/Library/LaunchDaemons/
	cp build/Tether build/rndis-tether $@/Contents/MacOS/
	$(SIGN) --identifier io.github.afn478.rndis-tether $@/Contents/MacOS/rndis-tether
	$(SIGN) $@

# SMAppService ties the helper to the app's location, so run it from /Applications.
install: $(APP)
	-pkill -x Tether
	rm -rf /Applications/Tether.app
	cp -R $(APP) /Applications/
	open /Applications/Tether.app

clean:
	rm -rf build

.PHONY: all install clean
