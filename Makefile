SHELL := /bin/bash

.PHONY: help format lint test build imsg clean

help:
	@printf "%s\n" \
		"make format  - swift format in-place" \
		"make lint    - swift format lint + swiftlint" \
		"make test    - sync version, patch deps, run swift test" \
		"make build   - universal release build into bin/" \
		"make imsg    - clean rebuild + run debug binary (ARGS=...)" \
		"make clean   - swift package clean"

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

build: build-helper
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	scripts/build-universal.sh

build-helper:
	@echo "Building imsg-helper (Objective-C)..."
	@mkdir -p .build/release
	@clang -fobjc-arc -framework Foundation -o .build/release/imsg-helper Sources/IMsgHelper/main.m
	@echo "Built imsg-helper successfully"

imsg: build-helper
	scripts/generate-version.sh
	swift package resolve
	scripts/patch-deps.sh
	swift package clean
	swift build -c debug --product imsg
	./.build/debug/imsg $(ARGS)

clean:
	swift package clean
