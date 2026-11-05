# Sofa — built with clang-22 against the 10.9 system frameworks (no SDK/Xcode needed).
# ARC only when compiling: linking with -fobjc-arc requires libarclite (missing, unneeded
# on 10.9, the runtime supports ARC natively).
# MP = MacPorts prefix (port: MP=${prefix}); PREFIX = target folder for Sofa.app
# (port: ${applications_dir}). CC = clang-22 (doctrine); ?= doesn't take effect for CC
# (make sets CC=cc), hence := and passing it on the command line (make CC=...).
# Never put comments after values: make would keep the spaces before them.
MP      ?= /opt/local
CC      := $(MP)/bin/clang
PREFIX  ?= /Applications
DESTDIR ?=
BUILD   := build
APP     := $(BUILD)/Sofa.app
BIN     := $(APP)/Contents/MacOS/Sofa
HBIN    := $(APP)/Contents/MacOS/SofaRemote
SRCDIRS := $(wildcard src/*/)   # sources by responsibility: App Core UI Player Providers YouTube Library
CFLAGS  := -I$(MP)/include -fobjc-arc -mmacosx-version-min=10.9 -O2 -g -Wall -Wno-deprecated-declarations \
           -Wno-unused-variable -Wno-unused-function $(addprefix -I,$(SRCDIRS))
LDFLAGS := -mmacosx-version-min=10.9 -framework Cocoa -framework QuartzCore -framework AVFoundation \
           -framework CoreMedia -framework IOKit -framework CoreServices -framework ImageIO -framework CoreAudio -framework AudioToolbox -framework SystemConfiguration -framework Security -L$(MP)/lib -lsqlite3 -lcurl
# libmpv (overlay port multimedia/mpv) optional + weakly linked: without it Sofa runs with AVFoundation only
ifneq ($(wildcard $(MP)/lib/libmpv.dylib),)
LDFLAGS += -framework OpenGL -weak-lmpv
endif
SRC     := $(wildcard src/*/*.m)
OBJ     := $(patsubst src/%.m,$(BUILD)/obj/%.o,$(SRC))
HSRC    := $(wildcard helper/*.m)
# the helper shares the runtime paths (SFRuntime) with Sofa
HOBJ    := $(patsubst helper/%.m,$(BUILD)/hobj/%.o,$(HSRC)) $(BUILD)/hobj/SFRuntime.o

DEVAPP  := $(BUILD)/SofaDev.app
DEVBIN  := $(DEVAPP)/Contents/MacOS/Sofa

# targets are FILES (directory mtime doesn't change on relink)
LOGOS   := $(patsubst res/logos/%,$(APP)/Contents/Resources/logos/%,$(wildcard res/logos/*.png))

# yt-dlp baseline (res/ytdlp.lock, tools/fetch-ytdlp) + verifier and public keys
# for updates (yt-dlp: maintainers' GPG; Sofa: its own RSA key, see SFSignature.h)
YTRES   := ytresolver.py ytdlp_verify.py yt-dlp-public.key sofa-release-public.pem
YTFILES := $(foreach b,$(APP) $(DEVAPP),$(addprefix $(b)/Contents/Resources/,$(YTRES)) $(b)/Contents/Resources/yt-dlp/VERSION)
VENDOR  := $(BUILD)/vendor/yt-dlp

# YouTube SABR sidecar (docs/sofa-yt.md): its sources + the npm dependencies pinned in
# res/sofa-yt/package-lock.json (tools/fetch-sofa-yt, npm ci) -> Contents/Resources/sofa-yt
SYSRC   := res/sofa-yt/package.json $(wildcard res/sofa-yt/*.mjs res/sofa-yt/lib/*.mjs)
SYVEND  := $(BUILD)/vendor/sofa-yt
SYFILES := $(foreach b,$(APP) $(DEVAPP),$(patsubst res/%,$(b)/Contents/Resources/%,$(SYSRC)) \
             $(b)/Contents/Resources/sofa-yt/node_modules/.sofa-stamp)

all: $(BIN) $(HBIN) $(APP)/Contents/Info.plist $(DEVBIN) $(LOGOS) $(YTFILES) $(SYFILES)

$(APP)/Contents/Resources/logos/%.png: res/logos/%.png
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/%: res/%
	@mkdir -p $(dir $@)
	cp $< $@
$(DEVAPP)/Contents/Resources/%: res/%
	@mkdir -p $(dir $@)
	cp $< $@

$(VENDOR)/VERSION: res/ytdlp.lock res/ytdlp_verify.py
	tools/fetch-ytdlp

$(APP)/Contents/Resources/yt-dlp/VERSION $(DEVAPP)/Contents/Resources/yt-dlp/VERSION: $(VENDOR)/VERSION
	@rm -rf $(dir $@) && mkdir -p $(dir $@)
	cp -R $(VENDOR)/ $(dir $@)

$(SYVEND)/STAMP: res/sofa-yt/package-lock.json
	tools/fetch-sofa-yt

$(APP)/Contents/Resources/sofa-yt/node_modules/.sofa-stamp $(DEVAPP)/Contents/Resources/sofa-yt/node_modules/.sofa-stamp: $(SYVEND)/STAMP
	@rm -rf $(dir $@) && mkdir -p $(dir $@)
	cp -R $(SYVEND)/node_modules/ $(dir $@)
	cp $(SYVEND)/STAMP $@

# Dev bundle with its own bundle ID (de.sofa.dev): invisible test/preview
# instances must never be confused with the real app (de.sofa.app)
# (LaunchServices/open, remote helper).
$(DEVBIN): $(BIN) res/Info.plist
	@mkdir -p $(DEVAPP)/Contents/MacOS
	@cp $(APP)/Contents/MacOS/Sofa $(DEVAPP)/Contents/MacOS/Sofa
	@sed -e 's/<string>de.sofa.app<\/string>/<string>de.sofa.dev<\/string>/' -e 's/<string>Sofa<\/string><\/dict>/&/' res/Info.plist > $(DEVAPP)/Contents/Info.plist

$(BUILD)/obj/%.o: src/%.m $(wildcard src/*/*.h)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/hobj/SFRuntime.o: src/Core/SFRuntime.m src/Core/SFRuntime.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/hobj/%.o: helper/%.m $(wildcard helper/*.h) src/App/SFRemote.h src/Core/SFCore.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BIN): $(OBJ)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(CC) $(OBJ) $(LDFLAGS) -o $@

$(HBIN): $(HOBJ)
	@mkdir -p $(APP)/Contents/MacOS
	$(CC) $(HOBJ) -mmacosx-version-min=10.9 -framework Cocoa -framework IOKit -o $@

$(APP)/Contents/Info.plist: res/Info.plist
	@mkdir -p $(APP)/Contents/Resources
	cp res/Info.plist $@
	@test -f res/Sofa.icns && cp res/Sofa.icns $(APP)/Contents/Resources/ || true

clean:
	rm -rf $(BUILD)

install: all
	mkdir -p $(DESTDIR)$(PREFIX)
	rm -rf $(DESTDIR)$(PREFIX)/Sofa.app && cp -R $(APP) $(DESTDIR)$(PREFIX)/

.PHONY: all clean install
