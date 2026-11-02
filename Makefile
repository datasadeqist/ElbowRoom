# SpareRoom build. Needs macOS 26 and the Xcode command line tools (xcode-select --install).
APP      := build/SpareRoom.app
DEST     := $(HOME)/Applications/SpareRoom.app
AGENT    := $(HOME)/Library/LaunchAgents/io.github.datasadeqist.spareroom.plist
# Ad-hoc signing ("-") is fine for an app you build yourself. To keep the permissions macOS
# remembers across rebuilds, sign with your own certificate: make install SIGN="Apple Development: Name (TEAMID)"
# Use a certificate that is still valid: macOS blocks apps signed with a revoked one as malware.
SIGN     ?= -

.PHONY: build install login unlogin uninstall clean

build:
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O Sources/SpareRoom.swift -o $(APP)/Contents/MacOS/SpareRoom
	cp Sources/Info.plist $(APP)/Contents/
	cp Sources/cleanup.sh Sources/sweep-worktrees.sh $(APP)/Contents/Resources/
	chmod +x $(APP)/Contents/Resources/*.sh
	codesign --force --sign "$(SIGN)" $(APP)

install: build
	-pkill -x SpareRoom
	rm -rf $(DEST) && mkdir -p $(HOME)/Applications && cp -R $(APP) $(DEST)
	open $(DEST)

# Start SpareRoom when you log in.
login: install
	mkdir -p $(dir $(AGENT))
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict><key>Label</key><string>io.github.datasadeqist.spareroom</string>' \
	  '<key>ProgramArguments</key><array><string>$(DEST)/Contents/MacOS/SpareRoom</string></array>' \
	  '<key>RunAtLoad</key><true/></dict></plist>' > $(AGENT)
	-launchctl bootout gui/$$(id -u)/io.github.datasadeqist.spareroom 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)

unlogin:
	-launchctl bootout gui/$$(id -u)/io.github.datasadeqist.spareroom 2>/dev/null
	rm -f $(AGENT)

uninstall: unlogin
	-pkill -x SpareRoom
	rm -rf $(DEST)
	-defaults delete io.github.datasadeqist.spareroom 2>/dev/null

clean:
	rm -rf build
