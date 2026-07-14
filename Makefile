DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

DERIVED := build/DerivedData
# First available iPhone simulator — never hardcode a model name.
SIM_ID = $(shell xcrun simctl list devices available | grep -E "iPhone" | head -1 | grep -oE "[0-9A-F-]{36}")
IPAD_ID = $(shell xcrun simctl list devices available | grep -E "iPad" | head -1 | grep -oE "[0-9A-F-]{36}")
BUNDLE := com.innovationBox.wallshader
APP := $(DERIVED)/Build/Products/Debug-iphonesimulator/Wallshader.app

.PHONY: project build test run screens clean

project:
	xcodegen generate

build: project
	xcodebuild -project WallshaderIOS.xcodeproj -scheme WallshaderIOS \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,id=$(SIM_ID)' build

test: project
	xcodebuild -project WallshaderIOS.xcodeproj -scheme WallshaderIOS \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,id=$(SIM_ID)' test

run: build
	xcrun simctl boot $(SIM_ID) 2>/dev/null || true
	xcrun simctl install $(SIM_ID) $(APP)
	xcrun simctl launch $(SIM_ID) $(BUNDLE)

# Screenshot sweep for Osman: boots, drives key screens via launch args,
# captures into Artifacts/run-<date>/.
screens: build
	./Tools/screens.sh $(SIM_ID) $(APP) $(BUNDLE)

clean:
	rm -rf build WallshaderIOS.xcodeproj
