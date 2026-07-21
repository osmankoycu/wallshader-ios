import ImageIO
import QuickLook
import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// QLPreviewController wrapper for the --ql-probe hook.
final class QLProbeController: QLPreviewController, QLPreviewControllerDataSource {
    private let fileURL: URL
    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        fileURL as NSURL
    }
}

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
        // Field probes drive the device from a Mac shell; don't let the
        // screen lock mid-diagnosis.
        if args.contains(where: { $0.hasPrefix("--strip-probe") || $0 == "--gpu-probe" }) {
            UIApplication.shared.isIdleTimerDisabled = true
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
        if args.contains("--gpu-probe") {
            runGPUProbe(app: app)
            return
        }
        if args.contains("--ql-probe") {
            runQuickLookProbe()
            return
        }
        if args.contains("--strip-probe") {
            runStripProbe(app: app)
            return
        }
        if let index = args.firstIndex(of: "--strip-probe-one"), index + 1 < args.count {
            runStripProbeOne(app: app, shaderId: args[index + 1])
            return
        }
        if args.contains("--strip-probe-calm") {
            // Same renders, but AFTER the launch-time thumbnail storm has
            // settled and strictly sequential — isolates concurrency as the
            // wedge trigger.
            Task { @MainActor in
                print("strip-probe-calm: waiting 8s for launch quiescence")
                try? await Task.sleep(for: .seconds(8))
                for id in ["mesh-gradient", "static-mesh-gradient", "grain-gradient",
                           "warp", "waves", "neuro-noise", "voronoi", "metaballs"] {
                    runStripProbeOneStep(app: app, shaderId: id)
                }
                print("strip-probe-calm: end")
                exit(0)
            }
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
            case "guide":
                app.showingGuideProbe = true
            case "onboarding":
                app.showingOnboarding = true
            default:
                break // library / settings are reachable as-is
            }
        }
    }

    /// Field diagnosis: prints each GPU bring-up step to stdout so a
    /// devicectl console launch shows exactly where a wedged device fails
    /// (pipelines, an offscreen render with a watchdog on
    /// waitUntilCompleted, texture upload). Exits when done.
    private static func runGPUProbe(app: AppModel) {
        func step(_ name: String, _ body: () -> String) {
            print("gpu-probe: \(name) START")
            let verdict = body()
            print("gpu-probe: \(name) -> \(verdict)")
        }
        print("gpu-probe: begin")
        guard let renderer = app.renderer else {
            print("gpu-probe: renderer INIT FAILED")
            exit(1)
        }
        print("gpu-probe: renderer ok, device=\(renderer.device.name)")
        for shader in ["mesh-gradient", "grain-gradient", "voronoi", "water", "halftone-dots"] {
            step("pipeline \(shader)") {
                do {
                    _ = try renderer.pipelineState(for: shader, pixelFormat: .bgra8Unorm)
                    return "ok"
                } catch {
                    return "FAILED: \(error)"
                }
            }
        }
        let offscreen = OffscreenRenderer(renderer: renderer)
        // Watchdog: if a render wedges in waitUntilCompleted, say so loudly
        // instead of hanging silently.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 6)
        watchdog.setEventHandler { print("gpu-probe: WATCHDOG - render did not complete in 6s (GPU wedged)") }
        watchdog.resume()
        step("offscreen render mesh-gradient 200x200") {
            guard let schema = ShaderRegistry.shared.schema(for: "mesh-gradient") else { return "no schema" }
            do {
                _ = try offscreen.renderImage(shaderId: "mesh-gradient",
                                              params: ShaderParams(schema: schema),
                                              pixelWidth: 200, pixelHeight: 200,
                                              pixelRatio: 2, timeSeconds: 0)
                return "ok"
            } catch {
                return "FAILED: \(error)"
            }
        }
        step("texture load bundled photo") {
            guard let url = Bundle.main.url(forResource: "test-image", withExtension: "jpg") else {
                return "no bundled image"
            }
            do {
                let texture = try renderer.loadTexture(url: url)
                return "ok \(texture.width)x\(texture.height)"
            } catch {
                return "FAILED: \(error)"
            }
        }
        watchdog.cancel()
        print("gpu-probe: end")
        exit(0)
    }

    /// Presents the system QLPreviewController on a generated .wallshader —
    /// the same preview-extension path Files/Messages use, so a screenshot
    /// shows whether OUR extension renders (simulator has no code-signing,
    /// isolating extension mechanics from provisioning).
    private static func runQuickLookProbe() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let json = #"{"formatVersion":1,"name":"QL Probe","shaderId":"mesh-gradient","params":{"speed":1},"animated":true}"#
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ql-probe.wallshader")
            try? json.write(to: url, atomically: true, encoding: .utf8)
            let controller = QLProbeController(fileURL: url)
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else { return }
            root.present(controller, animated: false)
        }
    }

    /// One shader, one process: renders `shaderId` offscreen at the strip's
    /// tile size, then bigger. A SIGKILLed launch = that shader wedges the
    /// GPU on this device; the shell loops over ids to map the blast radius.
    private static func runStripProbeOne(app: AppModel, shaderId: String) {
        runStripProbeOneStep(app: app, shaderId: shaderId)
        print("strip-probe-one: \(shaderId) end")
        exit(0)
    }

    private static func runStripProbeOneStep(app: AppModel, shaderId: String) {
        guard let renderer = app.renderer, let schema = ShaderRegistry.shared.schema(for: shaderId) else {
            print("strip-probe-one: \(shaderId) NO RENDERER/SCHEMA")
            return
        }
        let off = OffscreenRenderer(renderer: renderer)
        for (w, h) in [(192, 120), (400, 866)] {
            print("strip-probe-one: \(shaderId) \(w)x\(h) START")
            do {
                _ = try off.renderImage(shaderId: shaderId, params: ShaderParams(schema: schema),
                                        pixelWidth: w, pixelHeight: h, pixelRatio: 2,
                                        timeSeconds: 0)
                print("strip-probe-one: \(shaderId) \(w)x\(h) ok")
            } catch {
                print("strip-probe-one: \(shaderId) \(w)x\(h) FAIL \(error)")
            }
        }
    }

    /// Field diagnosis for the blank-strip bug: replays StripTileStore's
    /// exact render path in three phases and prints every step, so a
    /// devicectl console launch shows precisely which configuration wedges.
    /// A: sequential renders on the main thread. B: the real storm —
    /// concurrent Task.detached(.utility) renders. C: the storm again while
    /// a real document's live preview runs.
    private static func runStripProbe(app: AppModel) {
        print("strip-probe: begin")
        guard let renderer = app.renderer else {
            print("strip-probe: renderer INIT FAILED")
            exit(1)
        }
        let ids = StripTileStore.orderedIds(for: .procedural)
        print("strip-probe: \(ids.count) procedural shaders, device=\(renderer.device.name)")

        struct Box: @unchecked Sendable { let off: OffscreenRenderer }
        let box = Box(off: OffscreenRenderer(renderer: renderer))
        final class Progress: @unchecked Sendable {
            let lock = NSLock()
            var done: Set<String> = []
            func mark(_ id: String) { lock.lock(); done.insert(id); lock.unlock() }
            func missing(from ids: [String]) -> [String] {
                lock.lock(); defer { lock.unlock() }
                return ids.filter { !done.contains($0) }
            }
        }

        let render: @Sendable (String) throws -> Void = { id in
            guard let schema = ShaderRegistry.shared.schema(for: id) else { return }
            _ = try box.off.renderImage(shaderId: id, params: ShaderParams(schema: schema),
                                        pixelWidth: 192, pixelHeight: 120, pixelRatio: 2,
                                        timeSeconds: 0)
        }

        func storm(_ phase: String, then next: @escaping @Sendable () -> Void) {
            print("strip-probe: \(phase) storm START")
            // Lane probes: which execution lanes are alive at all?
            Task.detached(priority: .utility) { print("strip-probe: \(phase) lane detached-utility alive") }
            Task.detached(priority: .userInitiated) { print("strip-probe: \(phase) lane detached-userInitiated alive") }
            Task { print("strip-probe: \(phase) lane main-task alive") }
            DispatchQueue.global(qos: .utility).async { print("strip-probe: \(phase) lane gcd-utility alive") }
            let progress = Progress()
            for id in ids {
                Task.detached(priority: .utility) {
                    print("strip-probe: \(phase) \(id) task-running")
                    do {
                        try render(id)
                        print("strip-probe: \(phase) \(id) ok")
                    } catch {
                        print("strip-probe: \(phase) \(id) FAIL \(error)")
                    }
                    progress.mark(id)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                let missing = progress.missing(from: ids)
                print("strip-probe: \(phase) verdict after 15s — missing: "
                    + (missing.isEmpty ? "none" : missing.joined(separator: ",")))
                next()
            }
        }

        Task { @MainActor in
        // Let the launch-time thumbnail storm settle first, so phase A
        // measures renders in true isolation.
        print("strip-probe: waiting 8s for launch quiescence")
        try? await Task.sleep(for: .seconds(8))

        // Phase A: sequential, main thread — does ANY offscreen render work?
        for id in ids {
            print("strip-probe: A \(id) START")
            do { try render(id); print("strip-probe: A \(id) ok") }
            catch { print("strip-probe: A \(id) FAIL \(error)") }
        }

        // Phase B: the exact StripTileStore storm, no live preview.
        storm("B") {
            Task { @MainActor in
                // Phase C: open a real document (its live preview + display
                // link start), then storm again.
                if let doc = app.library.documents.first(where: { $0.kind == .procedural && $0.isAppliable }) {
                    app.open(doc.id)
                    print("strip-probe: C opened \(doc.name)")
                }
                try? await Task.sleep(for: .seconds(3))
                storm("C") {
                    print("strip-probe: end")
                    exit(0)
                }
            }
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
