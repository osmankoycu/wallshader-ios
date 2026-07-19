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
