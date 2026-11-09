# Sofa — built with clang-22 against the 10.9 system frameworks (no SDK/Xcode needed).
# ARC only when compiling: linking with -fobjc-arc requires libarclite (missing, unneeded
# on 10.9, the runtime supports ARC natively).
# MP = MacPorts prefix (port: MP=${prefix}); PREFIX = target folder for Sofa.app
# (port: ${applications_dir}). CC = clang-22 (doctrine); ?= doesn't take effect for CC
# (make sets CC=cc), hence := and passing it on the command line (make CC=...).
# Never put comments after values: make would keep the spaces before them.
MP      ?= /opt/local
# python for the build helpers (compile_commands.json); the port passes PYTHON=${prefix}/bin/python3.14
PYTHON  ?= python3
CC      := $(MP)/bin/clang
PREFIX  ?= /Applications
DESTDIR ?=
BUILD   := build
APP     := $(BUILD)/Sofa.app
BIN     := $(APP)/Contents/MacOS/Sofa
HBIN    := $(APP)/Contents/MacOS/SofaRemote
# layers (docs/architecture.md): Framework (TV UI) · Core/Library/Player (app-agnostic services) ·
# Apps/<App> (everything source-specific) · Shell (the Sofa product, wires apps in)
SRCDIRS := $(filter-out src/Apps/,$(wildcard src/*/)) $(wildcard src/Apps/*/)
CFLAGS  := -I$(MP)/include -fobjc-arc -mmacosx-version-min=10.9 -O2 -g -Wall -Wno-deprecated-declarations \
           -Wno-unused-variable -Wno-unused-function $(addprefix -I,$(SRCDIRS))
# linked libraries and their MacPorts ports (declared in the port's depends_lib):
#   mpv (+libmpv) -lmpv, sqlite3 -lsqlite3, curl -lcurl, webp -lwebp (WebP thumbnails, SFWebP)
# -headerpad_max_install_names: deploy/make-release rewrite every library path to the bundle's own
# copies (relink.py, longer paths); without room in the header that failed once the binary grew
# ("larger updated load commands do not fit", 2026-11-07)
LDFLAGS := -mmacosx-version-min=10.9 -headerpad_max_install_names -framework Cocoa -framework QuartzCore -framework OpenGL \
           -lmpv -framework IOKit -framework CoreServices -framework ImageIO -framework CoreAudio -framework IOBluetooth -framework AudioToolbox -framework SystemConfiguration -framework Security -L$(MP)/lib -lsqlite3 -lcurl -lwebp -lX11 -lXtst
# libmpv (overlay port multimedia/mpv) is the player engine: required
SRC     := $(wildcard src/*/*.m src/Apps/*/*.m)
OBJ     := $(patsubst src/%.m,$(BUILD)/obj/%.o,$(SRC))
HSRC    := $(wildcard helper/*.m)
# the helper shares the runtime paths (SFRuntime) with Sofa
HOBJ    := $(patsubst helper/%.m,$(BUILD)/hobj/%.o,$(HSRC)) $(BUILD)/hobj/SFRuntime.o

DEVAPP  := $(BUILD)/SofaDev.app
DEVBIN  := $(DEVAPP)/Contents/MacOS/Sofa

# targets are FILES (directory mtime doesn't change on relink)
LOGOS   := $(patsubst res/logos/%,$(APP)/Contents/Resources/logos/%,$(wildcard res/logos/*.png res/logos/marks/*.png))

# Sofa's own update key (SFSignature.h)
KEYFILES := $(foreach b,$(APP) $(DEVAPP),$(b)/Contents/Resources/sofa-release-public.pem)

# npm dependencies of the YouTube engine's build, pinned in res/sofa-yt/package-lock.json
# (tools/fetch-sofa-yt, npm ci; the port unpacks them from a distfile)
SYVEND  := $(BUILD)/vendor/sofa-yt

# YouTube engine extension (docs/youtube-engine.md): res/sofa-yt/web bundled by tools/build-yt-engine
# (esbuild-wasm) -> Contents/Resources/youtube-engine (SFYTBrowser installs it into the engine profile)
YESRC   := $(wildcard res/sofa-yt/web/*.ts res/sofa-yt/web/extension/* res/sofa-yt/lib/*.ts) res/sofa-yt/package-lock.json
YEFILES := $(foreach b,$(APP) $(DEVAPP),$(b)/Contents/Resources/youtube-engine/STAMP)

# user-facing changelog: Einstellungen -> "Neu in Version …"
NOTES_RES := $(foreach b,$(APP) $(DEVAPP),$(b)/Contents/Resources/CHANGELOG.md)

all: $(BIN) $(HBIN) $(APP)/Contents/Info.plist $(DEVBIN) $(LOGOS) $(KEYFILES) $(YEFILES) $(NOTES_RES) compile_commands.json

# clangd (editor / Claude Code LSP) compilation database from the build's own CC + CFLAGS
# (tools/gen-compile-commands). Machine-local absolute paths -> git-ignored. Depends on the
# source directories, so adding a file or a new src/Apps/<App> regenerates it.
UNITSRC := $(wildcard tests/units/*.m)
compile_commands.json: Makefile tools/gen-compile-commands $(SRCDIRS) $(wildcard helper/ tests/units/)
	@$(PYTHON) tools/gen-compile-commands $@ "$(CC)" "$(CFLAGS)" $(SRC) $(HSRC) $(UNITSRC)

$(APP)/Contents/Resources/CHANGELOG.md $(DEVAPP)/Contents/Resources/CHANGELOG.md: CHANGELOG.md
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/logos/%.png: res/logos/%.png
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/%: res/%
	@mkdir -p $(dir $@)
	cp $< $@
$(DEVAPP)/Contents/Resources/%: res/%
	@mkdir -p $(dir $@)
	cp $< $@

$(SYVEND)/STAMP: res/sofa-yt/package-lock.json
	tools/fetch-sofa-yt

$(BUILD)/sofa-yt-web/STAMP: $(YESRC) $(SYVEND)/STAMP tools/build-yt-engine
	tools/build-yt-engine

$(APP)/Contents/Resources/youtube-engine/STAMP $(DEVAPP)/Contents/Resources/youtube-engine/STAMP: $(BUILD)/sofa-yt-web/STAMP
	@rm -rf $(dir $@) && mkdir -p $(dir $@)
	cp -R $(BUILD)/sofa-yt-web/extension/ $(dir $@)
	cp $< $@

# Dev bundle with its own bundle ID (de.sofa.dev): invisible test/preview
# instances must never be confused with the real app (de.sofa.app)
# (LaunchServices/open, remote helper).
$(DEVBIN): $(BIN) res/Info.plist
	@mkdir -p $(DEVAPP)/Contents/MacOS
	@cp $(APP)/Contents/MacOS/Sofa $(DEVAPP)/Contents/MacOS/Sofa
	@sed -e 's/<string>de.sofa.app<\/string>/<string>de.sofa.dev<\/string>/' -e 's/<string>Sofa<\/string><\/dict>/&/' res/Info.plist > $(DEVAPP)/Contents/Info.plist

$(BUILD)/obj/%.o: src/%.m $(wildcard src/*/*.h src/Apps/*/*.h)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/hobj/SFRuntime.o: src/Core/SFRuntime.m src/Core/SFRuntime.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/hobj/%.o: helper/%.m $(wildcard helper/*.h) src/Shell/SFRemote.h src/Core/SFCore.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BIN): $(OBJ)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	$(CC) $(OBJ) $(LDFLAGS) -o $@

$(HBIN): $(HOBJ)
	@mkdir -p $(APP)/Contents/MacOS
	$(CC) $(HOBJ) -mmacosx-version-min=10.9 -headerpad_max_install_names -framework Cocoa -framework IOKit -o $@

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
