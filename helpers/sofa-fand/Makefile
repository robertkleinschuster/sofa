# sofa-fand - always-on fan control with a nightly learner (own build, independent of Sofa's Makefile).
#   make                 build (warnings are errors) + config check
#   make analyze         clang static analyzer, every source file
#   make test            the learned layer's validator + the learner against data from a known law
#   sudo make install    binary + reference config + both LaunchDaemons (daemon, nightly learner), (re)load
#   sudo make install-files  same without loading
#   sudo make uninstall  unload, fans back to the SMC, remove files (data and learned state stay in /var/db/sofa-fand)
# Never put comments after values: make would keep the spaces before them.
MP      ?= /opt/local
CC      := $(MP)/bin/clang
CFLAGS  := -mmacosx-version-min=10.9 -O2 -g -Wall -Wextra -Werror
LDFLAGS := -mmacosx-version-min=10.9 -framework IOKit -framework CoreFoundation -Wl,-bind_at_load
BIN     := sofa-fand
SBIN    := /usr/local/sbin
ETC     := /usr/local/etc
DB      := /var/db/sofa-fand
LABEL   := de.sofa.fand
PLIST   := /Library/LaunchDaemons/$(LABEL).plist
LLABEL  := de.sofa.fanlearn
LPLIST  := /Library/LaunchDaemons/$(LLABEL).plist

all: $(BIN) check

SRC     := $(wildcard src/*.c)
HDR     := $(wildcard src/*.h)
$(BIN): $(SRC) $(HDR) Makefile
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

check: $(BIN)
	./$(BIN) check -c sofa-fand.conf -l /nonexistent >/dev/null

test: $(BIN)
	tools/test-config.sh
	tools/test-learn.sh

analyze:
	for f in $(SRC); do $(CC) --analyze -Xanalyzer -analyzer-output=text -mmacosx-version-min=10.9 $$f -o /dev/null || exit 1; done

install: install-files
	launchctl load -w $(PLIST)
	launchctl load -w $(LPLIST)

# files only, jobs stay unloaded
install-files: $(BIN) check
	-launchctl unload $(LPLIST) 2>/dev/null
	-launchctl unload $(PLIST) 2>/dev/null
	install -d $(SBIN) $(ETC)
	install -d -m 755 -o root -g wheel $(DB) $(DB)/data
	install -m 755 -o root -g wheel $(BIN) $(SBIN)/$(BIN)
	install -m 644 -o root -g wheel sofa-fand.conf $(ETC)/sofa-fand.conf
	install -m 644 -o root -g wheel $(LABEL).plist $(PLIST)
	install -m 644 -o root -g wheel $(LLABEL).plist $(LPLIST)
	@echo "installed $$(shasum $(SBIN)/$(BIN) | cut -c1-12) from $$(git rev-parse --short HEAD 2>/dev/null)$$(git diff --quiet HEAD -- . 2>/dev/null || echo ' (+uncommitted changes)')"

uninstall:
	-launchctl unload $(LPLIST)
	-launchctl unload $(PLIST)
	-$(SBIN)/$(BIN) reset
	rm -f $(LPLIST) $(PLIST) $(SBIN)/$(BIN) $(ETC)/sofa-fand.conf

clean:
	rm -f $(BIN)
	rm -rf $(BIN).dSYM

.PHONY: all check test analyze install install-files uninstall clean
