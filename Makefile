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
#   make install    — copy built .app into /Applications
#   make clean

APP_NAME ?= WhisperWhy
BUNDLE_ID ?= com.ankur.whisperwhy
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES = $(CONTENTS)/Resources
ARCH ?= $(shell uname -m)

SOURCES = $(shell find Sources -name '*.swift' -type f ! -name SmokeMain.swift | LC_ALL=C sort)
WHISPER_LIB = $(BUILD_DIR)/whisper/src/libwhisper.a
WHISPER_GGML_LIBS = $(sort $(wildcard $(BUILD_DIR)/whisper/ggml/src/libggml*.a))
# Link whisper only when it has been built (`make whisper`); without it the
# app still builds — the whisper.cpp engine reports itself unavailable at
# runtime and Apple Speech remains usable.
WHISPER_LINK = $(if $(wildcard $(WHISPER_LIB)),$(WHISPER_LIB) $(WHISPER_GGML_LIBS),)
WHISPER_INC = vendor/whisper.cpp/include vendor/whisper.cpp/ggml/include
# Import whisper.h through an explicit module map (build/module/whisper.modulemap)
# so Swift can `import whisper` against the vendored C library.
WHISPER_SWIFT_FLAGS = $(if $(wildcard $(WHISPER_LIB)),\
	-Xcc -fmodule-map-file=$(PWD)/build/module/whisper.modulemap \
	-I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include \
	-Xcc -DWHISPER_SWIFT, )
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
		$(WHISPER_SWIFT_FLAGS) \
		$(SOURCES) \
		$(WHISPER_LINK) \
		-framework AppKit -framework SwiftUI -framework AVFoundation \
		-framework Metal -framework MetalKit -framework Accelerate -lc++ build/whisper/ggml/src/ggml-metal/libggml-metal.a build/whisper/ggml/src/ggml-blas/libggml-blas.a -framework Accelerate -framework Foundation
	@cp Info.plist "$(CONTENTS)/"
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$(RESOURCES)/" || true
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
	@mkdir -p "$(BUILD_DIR)/test-src"
	@cp Sources/*.swift $(BUILD_DIR)/test-src/
	@rm -f $(BUILD_DIR)/test-src/App.swift $(BUILD_DIR)/test-src/SmokeMain.swift
	swiftc \
		-warnings-as-errors \
		-o "$(TEST_RUNNER)" \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx14.0 \
		$(BUILD_DIR)/test-src/*.swift \
		Tests/TestMain.swift Tests/AppTests.swift Tests/main.swift \
		-framework AppKit -framework AVFoundation
	@$(TEST_RUNNER)

run: all
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3
	@open "$(APP_BUNDLE)"
	@echo "Launched $(APP_BUNDLE)"

install: all
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" /Applications/ || { \
		echo "Could not write to /Applications — trying ~/Applications instead"; \
		mkdir -p "$$HOME/Applications"; \
		rm -rf "$$HOME/Applications/$(APP_NAME).app"; \
		cp -R "$(APP_BUNDLE)" "$$HOME/Applications/"; \
	}
	@dest="/Applications/$(APP_NAME).app"; \
	[ -x "$$dest/Contents/MacOS/$(APP_NAME)" ] || dest="$$HOME/Applications/$(APP_NAME).app"; \
	[ -x "$$dest/Contents/MacOS/$(APP_NAME)" ] || { echo "Install failed: no executable in $$dest"; exit 1; }; \
	codesign --force --sign - "$$dest" >/dev/null 2>&1 || true; \
	xattr -dr com.apple.quarantine "$$dest" 2>/dev/null || true; \
	echo "Installed $$dest"

uninstall:
	@rm -rf "/Applications/$(APP_NAME).app"
	@echo "Removed /Applications/$(APP_NAME).app"

# CLI smoke: real whisper model over a WAV, no GUI. Compiles app sources with
# SmokeMain.swift as main.swift.
smoke:
	@mkdir -p $(BUILD_DIR)/smoke-src
	@cp Sources/*.swift $(BUILD_DIR)/smoke-src/
	@rm $(BUILD_DIR)/smoke-src/App.swift
	@mv $(BUILD_DIR)/smoke-src/SmokeMain.swift $(BUILD_DIR)/smoke-src/main.swift
	swiftc \
		-o $(BUILD_DIR)/smoke \
		-sdk $(shell xcrun --show-sdk-path) \
		-target $(ARCH)-apple-macosx14.0 \
		-D WW_SMOKE \
		-Xcc -fmodule-map-file=$(PWD)/build/module/whisper.modulemap \
		-I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include \
		$(BUILD_DIR)/smoke-src/*.swift \
		$(WHISPER_LIB) $(WHISPER_GGML_LIBS) \
		-framework AppKit -framework AVFoundation \
		-framework Metal -framework MetalKit -framework Accelerate -lc++ \
		build/whisper/ggml/src/ggml-metal/libggml-metal.a \
		build/whisper/ggml/src/ggml-blas/libggml-blas.a \
		-framework Accelerate -framework Foundation
	$(BUILD_DIR)/smoke vendor/whisper.cpp/samples/jfk.wav models/ggml-base.en.bin en

model:
	@mkdir -p models
	@bash scripts/fetch-model.sh $(MODEL)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run typecheck test smoke whisper model clean help
help:
	@echo "make | run | typecheck | test | smoke | whisper | model MODEL=... | clean"
