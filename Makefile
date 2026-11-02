# SpareRoom build. Needs macOS 26 and the Xcode command line tools (xcode-select --install).
APP      := build/SpareRoom.app
DEST     := $(HOME)/Applications/SpareRoom.app
MIN      := 26.0
# Ad-hoc signing ("-") is fine for an app you build yourself. To keep the permissions macOS
# remembers across rebuilds, sign with your own certificate: make install SIGN="Apple Development: Name (TEAMID)"
# Use a certificate that is still valid: macOS blocks apps signed with a revoked one as malware.
SIGN     ?= -

.PHONY: build install uninstall clean

# Universal app: Apple silicon and Intel.
build:
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources build/obj
	swiftc -O -target arm64-apple-macos$(MIN) Sources/SpareRoom.swift -o build/obj/SpareRoom-arm64
	swiftc -O -target x86_64-apple-macos$(MIN) Sources/SpareRoom.swift -o build/obj/SpareRoom-x86_64
	lipo -create build/obj/SpareRoom-arm64 build/obj/SpareRoom-x86_64 -output $(APP)/Contents/MacOS/SpareRoom
	cp Sources/Info.plist $(APP)/Contents/
	cp Sources/cleanup.sh Sources/sweep-worktrees.sh $(APP)/Contents/Resources/
	chmod +x $(APP)/Contents/Resources/*.sh
	codesign --force --sign "$(SIGN)" $(APP)

install: build
	-pkill -x SpareRoom
	rm -rf $(DEST) && mkdir -p $(HOME)/Applications && cp -R $(APP) $(DEST)
	open $(DEST)

# Turn off "Open at login" in Options first, or remove SpareRoom from System Settings > General > Login Items.
uninstall:
	-pkill -x SpareRoom
	rm -rf $(DEST)
	-defaults delete io.github.datasadeqist.spareroom 2>/dev/null

clean:
	rm -rf build
