# WhisperWhy — local dictation, notch style.
# Build mirrors FreeFlow's approach: raw `swiftc` into a hand-assembled .app
# bundle, no Xcode project. whisper.cpp is built separately by CMake and the
# app links the resulting static lib (see Phase 1).
#
# Targets:
#   make            — build build/WhisperWhy.app
#   make run        — build + kill old + launch
#   make typecheck  — swiftc -typecheck only
#   make test       — build+run unit test runner
#   make whisper    — clone+build vendored whisper.cpp (libwhisper.a, Metal on)
#   make model      — download a small Whisper ggml model into models/
#   make clean

APP_NAME ?= WhisperWhy
BUNDLE_ID ?= com.ankur.whisperwhy
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
WHISPER_LIB = $(BUILD_DIR)/whisper/src/libwhisper.a
WHISPER_GGML_LIBS = $(shell ls $(BUILD_DIR)/whisper/ggml/src/libggml*.a 2>/dev/null)
# Link whisper only when it has been built (`make whisper`); without it the
# app still builds — the whisper.cpp engine reports itself unavailable at
# runtime and Apple Speech remains usable.
WHISPER_LINK = $(if $(wildcard $(WHISPER_LIB)),$(WHISPER_LIB) $(WHISPER_GGML_LIBS),)
TEST_RUNNER = $(BUILD_DIR)/WhisperWhyTests

.PHONY: all run typecheck test whisper model clean

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) Info.plist
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	swiftc \
		-parse-as-library \
		-o "$(MACOS_DIR)/$(APP_NAME)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx14.0 \
		-parse-as-library \
		-O -whole-module-optimization \
		$(SOURCES) \
		$(WHISPER_LINK) \
		-framework AppKit -framework SwiftUI -framework AVFoundation \
		-framework Metal -framework MetalKit -framework Accelerate
	@cp Info.plist "$(CONTENTS)/"
	@codesign --force --options runtime --sign - --entitlements WhisperWhy.entitlements "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

# Typecheck without whisper libs: stub the C interop so plain `swiftc -typecheck`
# passes before `make whisper` has run.
typecheck:
	swiftc \
		-parse-as-library \
		-typecheck \
		-warnings-as-errors \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx14.0 \
		$(SOURCES)

test:
	@mkdir -p "$(BUILD_DIR)"
	swiftc \
		-parse-as-library \
		-warnings-as-errors \
		-o "$(TEST_RUNNER)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx14.0 \
		$(SOURCES) Tests/*.swift
	@$(TEST_RUNNER)

run: all
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	@open "$(APP_BUNDLE)"
	@echo "Launched $(APP_BUNDLE)"

whisper:
	@test -d vendor/whisper.cpp || git clone --depth 1 --branch v1.9.2 https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
	cmake -S vendor/whisper.cpp -B $(BUILD_DIR)/whisper -DCMAKE_BUILD_TYPE=Release \
		-DGGML_METAL=ON -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_EXAMPLES=OFF -DCMAKE_OSX_ARCHITECTURES=arm64
	cmake --build $(BUILD_DIR)/whisper --target whisper -j8

model:
	@mkdir -p models
	@bash scripts/fetch-model.sh $(MODEL)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: help
help:
	@echo "make          build app"
	@echo "make run      build + launch"
	@echo "make typecheck"
	@echo "make test"
	@echo "make whisper  build vendored whisper.cpp"
	@echo "make model    MODEL=base.en (default: small.en)"
	@echo "make clean"
