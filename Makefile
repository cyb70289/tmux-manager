APP_NAME    := TmuxManager
BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app
CONFIG      ?= release
INSTALL_DIR ?= /Applications
BIN_DIR     := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)

.PHONY: all build icon bundle install run uninstall test clean logs config

all: bundle

build:
	swift build -c $(CONFIG) --product $(APP_NAME)

icon: Resources/AppIcon.icns

Resources/AppIcon.icns: tools/MakeIcon.swift
	swift tools/MakeIcon.swift Resources/AppIcon.icns

bundle: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN_DIR)/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/attach.sh $(BUNDLE)/Contents/Resources/attach.sh
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	codesign --force --sign - --timestamp=none $(BUNDLE)
	@echo "Built $(BUNDLE)"

install: bundle
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R $(BUNDLE) "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

run: install
	open "$(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

test:
	swift test

logs:
	tail -n 60 "$(HOME)/Library/Application Support/TmuxManager/log.txt"

config:
	open -e "$(HOME)/Library/Application Support/TmuxManager/config.json"

clean:
	rm -rf $(BUILD_DIR) Resources/AppIcon.icns
	swift package clean
