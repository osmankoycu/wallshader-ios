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
	xcrun simctl boot $(SIM_ID) 2>/dev/null || true
	xcrun simctl privacy $(SIM_ID) grant photos-add $(BUNDLE) 2>/dev/null || true
	xcodebuild -project WallshaderIOS.xcodeproj -scheme WallshaderIOS \
		-configuration Debug -derivedDataPath $(DERIVED) \
		-destination 'platform=iOS Simulator,id=$(SIM_ID)' test

# iOS render harness (C10): renders every shader in the simulator, pulls
# the PNGs from the app container, and compares against Reference/ios with
# per-channel tolerance (never the Mac's byte-exact goldens — GPUs differ).
# First run with no goldens ADOPTS the output as the golden set.
render-test: build
	xcrun simctl boot $(SIM_ID) 2>/dev/null || true
	xcrun simctl install $(SIM_ID) $(APP)
	xcrun simctl terminate $(SIM_ID) $(BUNDLE) 2>/dev/null || true
	xcrun simctl launch $(SIM_ID) $(BUNDLE) --suppress-onboarding --render-test-ios render-test >/dev/null
	sleep 45
	rm -rf build/render-test && mkdir -p build/render-test
	cp "$$(xcrun simctl get_app_container $(SIM_ID) $(BUNDLE) data)/Documents/render-test/"*.png build/render-test/
	python3 Tools/compare-renders.py Reference/ios build/render-test

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
