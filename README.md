# Wallshader for iOS

The iPhone + iPad companion to [Wallshader for Mac](https://github.com/osmankoycu/wallshader):
full creation parity — library, editor, photo sources, per-device variants —
with wallpapers saved to Photos and set via the iOS Settings flow (iOS has
no set-wallpaper API, for any app).

Built as part of the **Wallshader v-Next** run; the driving spec is
`WALLSHADER-VNEXT-SPEC.md` (Osman's Desktop). All shared logic lives in the
Mac repo's SPM packages (`../wallshader/Packages/*`): ShaderCore,
WallshaderModel, WallshaderPalettes, UnsplashKit, WallshaderStoreCore,
AmbientBackdrop — this repo is the iOS shell (SwiftUI, PHPicker, Photos
export, Live Photo export, paywall, onboarding).

## Building

Requires Xcode 26, the sibling `wallshader` checkout, and XcodeGen:

    make build      # xcodegen + build for the first available iPhone simulator
    make run        # boot sim, install, launch
    make test       # unit tests
    make screens    # screenshot sweep into Artifacts/run-<date>/

`Config/unsplash-config.json` (gitignored) enables the Unsplash source; the
build copies the Mac repo's config automatically if present.
