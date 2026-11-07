APP := build/Farol.app
GHOSTTY := vendor/GhosttyKit.xcframework

.PHONY: help build release run install uninstall dist test lint icon clean shots shot

help:
	@echo "make build      debug build into $(APP)"
	@echo "make run        debug build and open it"
	@echo "make release    optimized build into $(APP)"
	@echo "make install    release build copied to /Applications"
	@echo "make uninstall  remove /Applications/Farol.app"
	@echo "make dist       signed and notarized zip for sharing (see scripts/dist.sh)"
	@echo "make test       run the FarolCore tests"
	@echo "make lint       style check for comments and docs"
	@echo "make icon       regenerate the app icon from assets/icon-source.png"
	@echo "make clean      remove build output (keeps libghostty)"
	@echo "make shots      open Farol Shots on a staged scene, SCENE=sidebar or review"
	@echo "make shot       save its window as site/features/NAME.png, NAME=review"

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
	@# Tell macOS the app changed, so Finder and the Dock drop the icon they cached.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Farol.app
	@echo "Installed /Applications/Farol.app"

dist: $(GHOSTTY)
	./scripts/dist.sh

uninstall:
	rm -rf /Applications/Farol.app

test: $(GHOSTTY)
	swift test

lint:
	python3 scripts/check-style.py

icon:
	swift scripts/make-icon.swift

shots: $(GHOSTTY)
	./scripts/bundle.sh shots
	./scripts/shots.sh stage $(SCENE)

shot:
	./scripts/shots.sh shoot $(NAME)

clean:
	rm -rf .build build
