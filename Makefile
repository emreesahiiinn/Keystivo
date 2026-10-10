# Keystivo developer commands. Uses the full Xcode toolchain even when
# xcode-select points at the Command Line Tools.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

PROJECT := Keystivo.xcodeproj
SCHEME := Keystivo
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Keystivo.app
PACKAGE := Packages/KeystivoKit

.PHONY: build release run test l10n-check clean

build: ## Debug build of the app
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build | grep -E "error:|warning: .*Keystivo|BUILD"

release: ## Optimized build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build | grep -E "error:|BUILD"

run: build ## Build, then (re)start the app
	-pkill -f "Keystivo.app/Contents/MacOS/Keystivo"
	open $(APP)

test: ## Unit tests for every module
	swift test --package-path $(PACKAGE)

l10n-check: ## Verify every string used in code exists in all languages
	python3 Scripts/l10n.py check

clean:
	rm -rf build $(PACKAGE)/.build
