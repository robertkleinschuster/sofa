# Sofa — Build mit clang-22 gegen die 10.9-System-Frameworks (kein SDK/Xcode nötig).
# ARC nur beim Kompilieren: der Link mit -fobjc-arc verlangt libarclite (fehlt, auf
# 10.9 unnötig, die Runtime kann ARC nativ).
# MP = MacPorts-Prefix (Port: MP=${prefix}); PREFIX = Zielordner für Sofa.app
# (Port: ${applications_dir}). CC = clang-22 (Doktrin); ?= greift bei CC nicht
# (make setzt CC=cc), daher := und Übergabe auf der Kommandozeile (make CC=...).
# Kommentare nie hinter Werte schreiben: make übernähme die Leerzeichen davor.
MP      ?= /opt/local
CC      := $(MP)/bin/clang
PREFIX  ?= /Applications
DESTDIR ?=
BUILD   := build
APP     := $(BUILD)/Sofa.app
BIN     := $(APP)/Contents/MacOS/Sofa
HBIN    := $(APP)/Contents/MacOS/SofaRemote
CFLAGS  := -I$(MP)/include -fobjc-arc -mmacosx-version-min=10.9 -O2 -g -Wall -Wno-deprecated-declarations \
           -Wno-unused-variable -Wno-unused-function -Isrc
LDFLAGS := -mmacosx-version-min=10.9 -framework Cocoa -framework QuartzCore -framework AVFoundation \
           -framework CoreMedia -framework IOKit -framework CoreServices -framework ImageIO -framework CoreAudio -framework AudioToolbox -framework SystemConfiguration -L$(MP)/lib -lsqlite3 -lcurl
# libmpv (Overlay-Port multimedia/mpv) optional + schwach gelinkt: fehlt sie, laeuft Sofa nur mit AVFoundation
ifneq ($(wildcard $(MP)/lib/libmpv.dylib),)
LDFLAGS += -framework OpenGL -weak-lmpv
endif
SRC     := $(wildcard src/*.m)
OBJ     := $(patsubst src/%.m,$(BUILD)/obj/%.o,$(SRC))
HSRC    := $(wildcard helper/*.m)
# der Helper teilt sich die Laufzeit-Pfade (SFRuntime) mit Sofa
HOBJ    := $(patsubst helper/%.m,$(BUILD)/hobj/%.o,$(HSRC)) $(BUILD)/hobj/SFRuntime.o

DEVAPP  := $(BUILD)/SofaDev.app
DEVBIN  := $(DEVAPP)/Contents/MacOS/Sofa

# Ziele sind DATEIEN (Verzeichnis-mtime ändert sich beim Relink nicht)
LOGOS   := $(patsubst res/logos/%,$(APP)/Contents/Resources/logos/%,$(wildcard res/logos/*.png))

all: $(BIN) $(HBIN) $(APP)/Contents/Info.plist $(DEVBIN) $(LOGOS) $(APP)/Contents/Resources/ytresolver.py $(DEVAPP)/Contents/Resources/ytresolver.py

$(APP)/Contents/Resources/logos/%.png: res/logos/%.png
	@mkdir -p $(dir $@)
	cp $< $@

$(APP)/Contents/Resources/ytresolver.py $(DEVAPP)/Contents/Resources/ytresolver.py: res/ytresolver.py
	@mkdir -p $(dir $@)
	cp $< $@

# Dev-Bundle mit eigener Bundle-ID (de.sofa.dev): unsichtbare Test-/Vorschau-
# Instanzen dürfen nie mit der echten App (de.sofa.app) verwechselt werden
# (LaunchServices/open, Remote-Helper).
$(DEVBIN): $(BIN) res/Info.plist
	@mkdir -p $(DEVAPP)/Contents/MacOS
	@cp $(APP)/Contents/MacOS/Sofa $(DEVAPP)/Contents/MacOS/Sofa
	@sed -e 's/<string>de.sofa.app<\/string>/<string>de.sofa.dev<\/string>/' -e 's/<string>Sofa<\/string><\/dict>/&/' res/Info.plist > $(DEVAPP)/Contents/Info.plist

$(BUILD)/obj/%.o: src/%.m $(wildcard src/*.h)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/hobj/SFRuntime.o: src/SFRuntime.m src/SFRuntime.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/hobj/%.o: helper/%.m $(wildcard helper/*.h) src/SFRemote.h src/SFCore.h
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
