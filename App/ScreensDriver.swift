import ImageIO
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// Launch-argument automation (C10): the CLI-shell-can't-screenshot gotcha
/// applies to simulators too, so `make screens` drives the app with launch
/// args and captures via simctl from outside.
///
///   --screen <name>        open a specific screen (library/editor/editor-photo/
///                          guide/paywall/onboarding/settings)
///   --render-test-ios <dir> render every shader once (tolerance-golden
///                          harness) into the app container and exit
///   --reset-onboarding     show onboarding regardless of the stored flag
@MainActor
enum ScreensDriver {
    static func prepareIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--reset-onboarding") {
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        }
        if args.contains("--suppress-onboarding") {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
    }

    static func runIfRequested(app: AppModel) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-test-ios"), index + 1 < args.count {
            runRenderTest(outDir: args[index + 1], app: app)
            return
        }
        if args.contains("--save-live-test") {
            runSaveLiveTest(app: app)
            return
        }
        if let index = args.firstIndex(of: "--ambient-test-ios"), index + 1 < args.count {
            runAmbientTest(outDir: args[index + 1], app: app)
            return
        }
        guard let index = args.firstIndex(of: "--screen"), index + 1 < args.count else { return }
        let screen = args[index + 1]
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            switch screen {
            case "editor":
                if let doc = app.library.documents.first(where: { $0.kind == .procedural && $0.isAppliable }) {
                    app.open(doc.id)
                }
            case "editor-photo":
                if let doc = app.library.documents.first(where: { $0.kind == .imageBased && $0.isAppliable }) {
                    app.open(doc.id)
                }
            case "paywall":
                app.showingPaywall = true
            case "onboarding":
                app.showingOnboarding = true
            default:
                break // library / settings are reachable as-is
            }
        }
    }

    /// End-to-end Live Photo save (the TCC-abort regression): renders the
    /// first animatable wallpaper, assembles + saves the pair, exits 0/1.
    /// Needs photos-add granted (`simctl privacy grant photos-add`). The
    /// simulator enforces usage-description aborts like hardware, so a
    /// library READ sneaking back into the save path fails this run.
    private static func runSaveLiveTest(app: AppModel) {
        Task { @MainActor in
            guard let doc = app.library.documents.first(where: { $0.shaderIsAnimatable && $0.isAppliable }) else {
                print("save-live-test: no animatable wallpaper")
                exit(1)
            }
            let model = EditorModel(app: app, documentID: doc.id)
            model.setAnimated(true)
            do {
                try await LivePhotoExporter.saveLiveWallpaper(model: model)
                print("save-live-test: PASS")
                exit(0)
            } catch {
                print("save-live-test: FAIL \(error)")
                exit(1)
            }
        }
    }

    /// Functional ambient sweep (the Mac's `make ambient-test`, iOS-grade):
    /// composes the bundled photo small-in-frame through the ambient
    /// pre-pass at knob extremes, every mask shape, disabled, and a moved/
    /// shrunk placement — synchronously (waitForBackdrop). Instead of
    /// byte-goldens it asserts behavior: the backdrop must EXIST (enabled
    /// border ≫ disabled border), every variant must differ from base, and
    /// the halo must follow the photo. Exits 0/1; frames land in Documents
    /// for eyeballing.
    private static func runAmbientTest(outDir: String, app: AppModel) {
        // "water" preserves tones (a quantizing shader like halftone-dots
        // rounds away the backdrop's brightness response and blinds the
        // assertions below).
        guard let renderer = app.renderer,
              let photoURL = Bundle.main.url(forResource: "test-image", withExtension: "jpg"),
              let texture = try? renderer.loadTexture(url: photoURL),
              let schema = ShaderRegistry.shared.schema(for: "water") else {
            print("ambient-test-ios: setup failed"); exit(1)
        }
        let out = URL(fileURLWithPath: outDir, relativeTo:
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let offscreen = OffscreenRenderer(renderer: renderer)

        var params = ShaderParams(schema: schema)
        params["fit"] = .choice("contain")
        params["scale"] = .number(0.55)

        func spec(_ settings: AmbientSettings) -> AmbientRenderSpec {
            AmbientRenderSpec(
                contentKey: "ambient-test",
                loadImage: {
                    guard let src = CGImageSourceCreateWithURL(photoURL as CFURL, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(src, 0, nil)
                },
                settings: settings, waitForBackdrop: true)
        }
        func render(_ name: String, settings: AmbientSettings,
                    patch: [String: ParamValue] = [:]) -> CGImage? {
            var p = params
            for (k, v) in patch { p[k] = v }
            let image = try? offscreen.renderImage(
                shaderId: schema.id, params: p, pixelWidth: 590, pixelHeight: 1280,
                pixelRatio: 3, timeSeconds: 0, texture: texture, ambient: spec(settings))
            if let image { try? offscreen.writePNG(image, to: out.appendingPathComponent("\(name).png")) }
            return image
        }
        // Mean luminance of the outer 8 % border band (backdrop territory).
        func borderMean(_ image: CGImage) -> Double {
            let w = image.width, h = image.height
            guard let data = image.dataProvider?.data as Data? else { return 0 }
            let bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8
            let inset = Int(Double(min(w, h)) * 0.08)
            var sum = 0.0, count = 0.0
            for y in stride(from: 0, to: h, by: 4) {
                for x in stride(from: 0, to: w, by: 4) {
                    guard x < inset || x >= w - inset || y < inset || y >= h - inset else { continue }
                    let o = y * bpr + x * bpp
                    sum += Double(data[o]) + Double(data[o + 1]) + Double(data[o + 2])
                    count += 3
                }
            }
            return count > 0 ? sum / count : 0
        }
        func differs(_ a: CGImage?, _ b: CGImage?) -> Bool {
            guard let a, let b,
                  let da = a.dataProvider?.data as Data?,
                  let db = b.dataProvider?.data as Data? else { return false }
            return da != db
        }

        var failures: [String] = []
        let base = render("base", settings: .automatic)
        let disabled = render("disabled", settings: AmbientSettings(enabled: false))
        if let base, let disabled {
            // Direction-agnostic: enabling ambient must CHANGE the border
            // band substantially (the backdrop replaces whatever letterbox
            // the shader draws — darker or lighter depends on content).
            let on = borderMean(base), off = borderMean(disabled)
            if abs(on - off) < 8 { failures.append("backdrop-missing (border on=\(on) off=\(off))") }
        } else {
            failures.append("base/disabled render failed")
        }
        // Brightness is a live compose uniform — the border must dim.
        if let base, let dim = render("dim-check", settings: AmbientSettings(backdropBrightness: 0.2)),
           borderMean(dim) >= borderMean(base) - 5 {
            failures.append("brightness-dead (base=\(borderMean(base)) dim=\(borderMean(dim)))")
        }
        let variants: [(String, AmbientSettings)] = [
            ("softness-0", AmbientSettings(edgeSoftness: 0)),
            ("softness-1", AmbientSettings(edgeSoftness: 1)),
            ("blur-0", AmbientSettings(backdropBlur: 0)),
            ("blur-1", AmbientSettings(backdropBlur: 1)),
            ("dark", AmbientSettings(backdropBrightness: 0.3)),
            ("rounded", AmbientSettings(maskShape: .roundedRectangle)),
            ("ellipse", AmbientSettings(maskShape: .ellipse)),
            ("circle", AmbientSettings(maskShape: .circle)),
        ]
        for (name, settings) in variants {
            let image = render(name, settings: settings)
            if !differs(image, base) { failures.append("\(name) identical to base") }
        }
        let moved = render("moved", settings: .automatic,
                           patch: ["scale": .number(0.4), "offsetX": .number(0.3),
                                   "offsetY": .number(0.2)])
        if !differs(moved, base) { failures.append("moved identical to base (halo not following)") }

        if failures.isEmpty {
            print("ambient-test-ios: PASS (12 frames)")
            exit(0)
        } else {
            print("ambient-test-ios: FAIL — \(failures.joined(separator: "; "))")
            exit(1)
        }
    }

    /// The iOS render harness (C10): every shader at its default params,
    /// 2 frames for animated ones — written into the app container, pulled
    /// out via `simctl get_app_container` and compared with tolerance
    /// (never against the Mac's byte-exact goldens; GPUs differ).
    private static func runRenderTest(outDir: String, app: AppModel) {
        guard let renderer = app.renderer else { exit(1) }
        let out = URL(fileURLWithPath: outDir, relativeTo:
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let offscreen = OffscreenRenderer(renderer: renderer)
        let texture: MTLTexture? = Bundle.main.url(forResource: "test-image", withExtension: "jpg")
            .flatMap { try? renderer.loadTexture(url: $0) }
        var failures = 0
        for id in ShaderRegistry.shared.orderedIds {
            guard let schema = ShaderRegistry.shared.schema(for: id) else { continue }
            let params = ShaderParams(schema: schema)
            let times: [Float] = schema.animated ? [0, 7] : [0]
            for t in times {
                do {
                    let image = try offscreen.renderImage(
                        shaderId: id, params: params,
                        pixelWidth: 800, pixelHeight: 500, pixelRatio: 2,
                        timeSeconds: t,
                        texture: schema.needsTexture ? texture : nil)
                    let suffix = t == 0 ? "" : "@\(Int(t))s"
                    try offscreen.writePNG(image, to: out.appendingPathComponent("\(id)\(suffix).png"))
                } catch {
                    failures += 1
                    print("render-test-ios: FAILED \(id): \(error)")
                }
            }
        }
        print("render-test-ios: done, failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
