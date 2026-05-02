SHELL := /bin/bash

# Common commands for the Swift vMLX dev workflow. Just a flat list of
# named recipes — no implicit dependency tracking, no incremental
# logic. Run them as you need them.
#
#   make build      build/xcode/Build/Products/Debug/vMLX.app
#   make release    build/xcode/Build/Products/Release/vMLX.app
#   make cli        .build/.../debug/vmlxctl   + staged metallib
#   make cli-release
#   make run        build + relaunch (Release)
#   make run-debug  build + relaunch (Debug)
#   make regen      regenerate vMLX.xcodeproj from project.yml
#   make open       open vMLX.xcodeproj in Xcode
#   make clean      drop build/xcode and .build
#
# Code signing: ad-hoc (-) so we can build without Apple Developer ID
# enrollment. Mirrors the local-only override applied to project.yml.
# Do NOT use these settings for distribution builds.
#
# IMPORTANT: the .app and CLI builds are kept disjoint. If `swift build`
# has populated `.build/`, the Xcode `vMLX` app target sometimes picks
# up the SwiftPM `vMLX` executable as a dependency artifact and ends up
# overwriting `vMLX.app` with a bare binary. The `cli` target uses
# .build/, the app target uses build/xcode/ — don't mix.

XCFLAGS := CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

.DEFAULT_GOAL := build

.PHONY: build
build:
	xcodegen
	xcodebuild -project vMLX.xcodeproj -scheme vMLX \
	  -configuration Debug -derivedDataPath build/xcode $(XCFLAGS) build

.PHONY: release
release:
	xcodegen
	xcodebuild -project vMLX.xcodeproj -scheme vMLX \
	  -configuration Release -derivedDataPath build/xcode $(XCFLAGS) build

.PHONY: cli
cli:
	swift build -c debug
	./scripts/stage-metallib.sh debug

.PHONY: cli-release
cli-release:
	swift build -c release
	./scripts/stage-metallib.sh release

.PHONY: run
run: release
	./swift-launch.sh

.PHONY: run-debug
run-debug: build
	./swift-launch.sh --debug

.PHONY: regen
regen:
	xcodegen

.PHONY: open
open:
	xcodegen
	open vMLX.xcodeproj

.PHONY: clean
clean:
	rm -rf build/xcode .build
