# sofa-fand - quiet fan control for Sofa's rest mode (own build, independent of Sofa's Makefile).
#   make                 build
#   sudo make install    binary + config + LaunchDaemon, (re)load it
#   sudo make uninstall  unload, fans back to the SMC, remove files
# Never put comments after values: make would keep the spaces before them.
MP      ?= /opt/local
CC      := $(MP)/bin/clang
CFLAGS  := -mmacosx-version-min=10.9 -O2 -g -Wall -Wextra
LDFLAGS := -mmacosx-version-min=10.9 -framework IOKit -framework CoreFoundation
BIN     := sofa-fand
LABEL   := de.sofa.fand
SBIN    := /usr/local/sbin
ETC     := /usr/local/etc
PLIST   := /Library/LaunchDaemons/$(LABEL).plist

all: $(BIN)

$(BIN): sofa-fand.c Makefile
	$(CC) $(CFLAGS) -o $@ sofa-fand.c $(LDFLAGS)

check: $(BIN)
	./$(BIN) check -c sofa-fand.conf

install: $(BIN) check
	-launchctl unload $(PLIST) 2>/dev/null
	install -d $(SBIN) $(ETC)
	install -m 755 -o root -g wheel $(BIN) $(SBIN)/$(BIN)
	install -m 644 -o root -g wheel sofa-fand.conf $(ETC)/sofa-fand.conf
	install -m 644 -o root -g wheel $(LABEL).plist $(PLIST)
	launchctl load -w $(PLIST)

uninstall:
	-launchctl unload $(PLIST)
	-$(SBIN)/$(BIN) reset
	rm -f $(PLIST) $(SBIN)/$(BIN) $(ETC)/sofa-fand.conf

clean:
	rm -rf $(BIN) $(BIN).dSYM

.PHONY: all check install uninstall clean
