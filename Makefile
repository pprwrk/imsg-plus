SHELL := /bin/bash

.PHONY: help format lint test build imsg clean build-dylib build-helper

help:
	@printf "%s\n" \
		"make format     - swift format in-place" \
		"make lint       - swift format lint + swiftlint" \
		"make test       - sync version, patch deps, run swift test" \
		"make build      - universal release build into bin/" \
		"make build-dylib - build injectable dylib for Messages.app" \
		"make imsg       - clean rebuild + run debug binary (ARGS=...)" \
		"make clean      - swift package clean"

format:
	swift format --in-place --recursive Sources Tests

lint:
	swift format lint --recursive Sources Tests
	swiftlint

test:
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift test

build: build-dylib
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	scripts/build-universal.sh

# Build injectable dylib for Messages.app (DYLD_INSERT_LIBRARIES)
# Uses arm64e architecture to match Messages.app on Apple Silicon
build-dylib:
	@echo "Building imsg-plus-helper.dylib (injectable)..."
	@mkdir -p .build/release
	@clang -dynamiclib -arch arm64e -fobjc-arc \
		-framework Foundation \
		-o .build/release/imsg-plus-helper.dylib \
		Sources/IMsgHelper/IMsgInjected.m
	@echo "Built imsg-plus-helper.dylib successfully"
	@echo "To test manually:"
	@echo "  killall Messages 2>/dev/null; sleep 1"
	@echo "  DYLD_INSERT_LIBRARIES=.build/release/imsg-plus-helper.dylib /System/Applications/Messages.app/Contents/MacOS/Messages &"

# Legacy standalone helper (kept for backward compatibility)
build-helper:
	@echo "Building imsg-helper (standalone, Objective-C)..."
	@mkdir -p .build/release
	@clang -fobjc-arc -framework Foundation -o .build/release/imsg-helper Sources/IMsgHelper/main.m
	@echo "Built imsg-helper successfully"

imsg: build-dylib
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift package clean
	swift build -c debug --product imsg
	./.build/debug/imsg $(ARGS)

clean:
	swift package clean
	@rm -f .build/release/imsg-plus-helper.dylib
	@rm -f .build/release/imsg-helper
