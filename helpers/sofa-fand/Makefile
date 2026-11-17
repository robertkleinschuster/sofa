# sofa-fand - always-on fan control (own build, independent of Sofa's Makefile).
#   make                 build (warnings are errors) + config check
#   make analyze         clang static analyzer
#   sudo make install    binary + config + LaunchDaemon, (re)load it
#   sudo make install-files  same without loading
#   sudo make uninstall  unload, fans back to the SMC, remove files
#   make tools           measurement tools in tools/ (smcfan, smcenum, smarttemp, fanlab)
# Never put comments after values: make would keep the spaces before them.
MP      ?= /opt/local
CC      := $(MP)/bin/clang
CFLAGS  := -mmacosx-version-min=10.9 -O2 -g -Wall -Wextra -Werror
LDFLAGS := -mmacosx-version-min=10.9 -framework IOKit -framework CoreFoundation
DLDFLAGS := $(LDFLAGS) -Wl,-bind_at_load
BIN     := sofa-fand
LABEL   := de.sofa.fand
SBIN    := /usr/local/sbin
ETC     := /usr/local/etc
PLIST   := /Library/LaunchDaemons/$(LABEL).plist
TOOLS   := tools/smcfan tools/smcenum tools/smarttemp tools/fanlab

all: $(BIN) check

$(BIN): sofa-fand.c Makefile
	$(CC) $(CFLAGS) -o $@ sofa-fand.c $(DLDFLAGS)

check: $(BIN)
	./$(BIN) check -c sofa-fand.conf >/dev/null

analyze:
	$(CC) --analyze -mmacosx-version-min=10.9 sofa-fand.c

tools: $(TOOLS)

tools/%: tools/%.c Makefile
	$(CC) -mmacosx-version-min=10.9 -O2 -Wall -Wextra -Wno-unused-parameter -o $@ $< $(LDFLAGS)

install: install-files
	launchctl load -w $(PLIST)

# files only, daemon stays unloaded (e.g. while fan measurements run)
install-files: $(BIN) check
	-launchctl unload $(PLIST) 2>/dev/null
	install -d $(SBIN) $(ETC)
	install -m 755 -o root -g wheel $(BIN) $(SBIN)/$(BIN)
	install -m 644 -o root -g wheel sofa-fand.conf $(ETC)/sofa-fand.conf
	install -m 644 -o root -g wheel $(LABEL).plist $(PLIST)
	@echo "installed $$(shasum $(SBIN)/$(BIN) | cut -c1-12) from $$(git rev-parse --short HEAD 2>/dev/null)$$(git diff --quiet HEAD -- . 2>/dev/null || echo ' (+uncommitted changes)')"

uninstall:
	-launchctl unload $(PLIST)
	-$(SBIN)/$(BIN) reset
	rm -f $(PLIST) $(SBIN)/$(BIN) $(ETC)/sofa-fand.conf

clean:
	rm -f $(BIN) $(TOOLS)
	rm -rf $(BIN).dSYM

.PHONY: all check analyze tools install install-files uninstall clean
