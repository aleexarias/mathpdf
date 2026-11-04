# XcodeGen turns project.yml into mathpdf.xcodeproj. This uses the one on
# PATH, else one installed with conda.
CONDA_XCODEGEN := \
    $(firstword $(wildcard $(HOME)/miniconda3/envs/*/bin/xcodegen))
XCODEGEN ?= $(or $(shell command -v xcodegen),$(CONDA_XCODEGEN),xcodegen)
DERIVED := build/DerivedData
XCODEPROJECT := xcodebuild -project mathpdf.xcodeproj -scheme mathpdf \
    -derivedDataPath $(DERIVED)
XCODEBUILD := $(XCODEPROJECT) -destination 'platform=macOS,arch=arm64'
APP := $(DERIVED)/Build/Products/Debug/mathpdf.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/mathpdf.app
INSTALL_DIR ?= /Applications
INSTALLED_APP := $(INSTALL_DIR)/mathpdf.app
CORESERVICES := /System/Library/Frameworks/CoreServices.framework
LAUNCHSERVICES := $(CORESERVICES)/Frameworks/LaunchServices.framework
LSREGISTER := $(LAUNCHSERVICES)/Support/lsregister

# The installed app and the one `make run` builds share a bundle ID and the
# annotations folder, so only one of them may run at a time.
define refuse-if-running
	@if pgrep -qf '$(1)/Contents/MacOS/mathpdf'; then \
		echo "Quit the mathpdf in $(dir $(1)) first."; exit 1; \
	fi
endef

.PHONY: project build test run install icon format lint clean

project:
	$(XCODEGEN) generate --quiet

build: project
	$(XCODEBUILD) -quiet build

test: project
	$(XCODEBUILD) -quiet test

run: build
	$(call refuse-if-running,$(INSTALLED_APP))
	open $(APP)

# A Release build for Apple silicon and Intel, copied to /Applications (or
# INSTALL_DIR). Run it again to update: the old copy is replaced; annotations
# live outside the app and are kept.
install: project
	$(call refuse-if-running,$(INSTALLED_APP))
	$(XCODEPROJECT) -configuration Release -quiet build \
		-destination 'generic/platform=macOS' \
		ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO
	rm -rf '$(INSTALL_DIR)/.mathpdf.app.new'
	ditto '$(RELEASE_APP)' '$(INSTALL_DIR)/.mathpdf.app.new'
	rm -rf '$(INSTALLED_APP)'
	mv '$(INSTALL_DIR)/.mathpdf.app.new' '$(INSTALLED_APP)'
	$(LSREGISTER) -f '$(INSTALLED_APP)'
	@echo 'Installed $(INSTALLED_APP)'

# Redraws App/Assets.xcassets/AppIcon.appiconset after a change to the script.
icon:
	xcrun swift scripts/AppIcon.swift

# Code style: .swift-format, applied with Xcode's swift-format.
SOURCES := App scripts/AppIcon.swift Packages/MathPDFCore/Package.swift \
    Packages/MathPDFCore/Sources Packages/MathPDFCore/Tests
FORMAT_FLAGS := --configuration .swift-format --recursive

format:
	xcrun swift-format format $(FORMAT_FLAGS) --in-place $(SOURCES)

lint:
	xcrun swift-format lint $(FORMAT_FLAGS) --strict $(SOURCES)

clean:
	rm -rf build mathpdf.xcodeproj
