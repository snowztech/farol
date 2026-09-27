APP := build/Farol.app
GHOSTTY := vendor/GhosttyKit.xcframework

.PHONY: help build release run install uninstall test check icon clean

help:
	@echo "make build      debug build into $(APP)"
	@echo "make run        debug build and open it"
	@echo "make release    optimized build into $(APP)"
	@echo "make install    release build copied to /Applications"
	@echo "make uninstall  remove /Applications/Farol.app"
	@echo "make test       run the FarolCore tests"
	@echo "make check      style check for comments and docs"
	@echo "make icon       regenerate the app icon from assets/icon-source.png"
	@echo "make clean      remove build output (keeps libghostty)"

# Built once, then reused. Delete vendor/ to rebuild it.
$(GHOSTTY):
	./scripts/build-ghostty.sh

build: $(GHOSTTY)
	./scripts/bundle.sh debug

release: $(GHOSTTY)
	./scripts/bundle.sh release

run: build
	open $(APP)

install: release
	rm -rf /Applications/Farol.app
	cp -R $(APP) /Applications/Farol.app
	@echo "Installed /Applications/Farol.app"

uninstall:
	rm -rf /Applications/Farol.app

test: $(GHOSTTY)
	swift test

check:
	python3 scripts/check-style.py

icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build build
