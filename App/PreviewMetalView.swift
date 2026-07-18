import ShaderCore
import SwiftUI
import UIKit
import WallshaderModel

/// The iOS editor preview: a CADisplayLink-driven CAMetalLayer over the
/// shared ShaderCore render core (the iOS counterpart of the Mac's
/// PreviewView, which drives itself from NSScreen.displayLink per the
/// MTKView gotcha). Respects the frame-rate cap, drops to 30 fps in Low
/// Power Mode (spec C2) and under serious thermal pressure.
struct PreviewMetalView: UIViewRepresentable {
    /// How much rendering this instance is allowed to do. `.live` animates;
    /// `.still` renders only on demand (first frame, param changes) so
    /// off-current pager pages don't burn GPU; `.frozen` renders nothing
    /// and keeps the last presented frame (pages covered by the editor,
    /// scene-phase pause).
    enum Mode {
        case live
        case still
        case frozen
    }

    @ObservedObject var model: PreviewModel
    var mode: Mode = .live

    func makeUIView(context: Context) -> MetalHostView {
        let view = MetalHostView()
        view.model = model
        view.mode = mode
        return view
    }

    func updateUIView(_ view: MetalHostView, context: Context) {
        view.model = model
        view.mode = mode
        view.setNeedsRender()
    }

    final class MetalHostView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

        var model: PreviewModel? {
            didSet { configureIfNeeded() }
        }
        var mode: PreviewMetalView.Mode = .live {
            didSet {
                if oldValue == .frozen, mode != .frozen { needsRender = true }
            }
        }
        private var link: CADisplayLink?
        private var configured = false
        private var frameInFlight = false

        /// CADisplayLink RETAINS its target — pointing it straight at the
        /// view made deinit unreachable, so every dismissed editor / swiped
        /// pager page left a zombie 60 fps render loop behind (the device-
        /// heating bug). The weak proxy breaks the cycle; the link itself
        /// lives only while the view is in a window.
        private final class LinkProxy: NSObject {
            weak var view: MetalHostView?
            init(view: MetalHostView) { self.view = view }
            @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
        }

        private func configureIfNeeded() {
            guard !configured, let model, let renderer = model.renderer else { return }
            configured = true
            metalLayer.device = renderer.device
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.framebufferOnly = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)

            for name: Notification.Name in [UserDefaults.didChangeNotification,
                                            .NSProcessInfoPowerStateDidChange,
                                            ProcessInfo.thermalStateDidChangeNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                                                       name: name, object: nil)
            }
            // Still previews park on needsRender — an async halo compute
            // finishing must wake them or the fresh backdrop pops in only
            // on the next unrelated repaint (the Mac learned this too).
            NotificationCenter.default.addObserver(self, selector: #selector(backdropReady),
                                                   name: AmbientBackdropStore.backdropDidBecomeReady,
                                                   object: nil)
            if window != nil { startLink() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                link?.invalidate()
                link = nil
            } else if configured {
                startLink()
                needsRender = true
            }
        }

        private func startLink() {
            guard link == nil else { return }
            let link = CADisplayLink(target: LinkProxy(view: self), selector: #selector(LinkProxy.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            applyFrameRate()
        }

        @objc private func environmentChanged() {
            DispatchQueue.main.async { [weak self] in self?.applyFrameRate() }
        }

        @objc private func backdropReady() {
            DispatchQueue.main.async { [weak self] in self?.setNeedsRender() }
        }

        private func applyFrameRate() {
            let cap = Float(UserDefaults.standard.integer(forKey: "liveFrameRateCap"))
            let base: Float = cap > 0 ? cap : 60
            var effective = ProcessInfo.processInfo.isLowPowerModeEnabled ? min(base, 30) : base
            switch ProcessInfo.processInfo.thermalState {
            case .serious: effective = min(effective, 30)
            case .critical: effective = min(effective, 15)
            default: break
            }
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: effective,
                                                             preferred: effective)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = window?.screen.scale ?? UIScreen.main.scale
            metalLayer.contentsScale = scale
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
                metalLayer.drawableSize = size
                setNeedsRender()
            }
        }

        func setNeedsRender() { needsRender = true }
        private var needsRender = true

        @objc private func tick(_ link: CADisplayLink) {
            guard let model, !frameInFlight, mode != .frozen else { return }
            let animating = model.isPlaying && mode == .live
            if !animating && !needsRender { return }
            needsRender = false
            render(model: model)
        }

        private func render(model: PreviewModel) {
            guard let renderer = model.renderer,
                  metalLayer.drawableSize.width > 0,
                  let drawable = metalLayer.nextDrawable(),
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
            frameInFlight = true

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            let time = model.currentTimeSeconds()
            // Miniature the target device's canonical wallpaper, exactly
            // like the Mac canvas miniatures the screen (shared math).
            let target = model.emulatedPixels
            let drawablePx = SIMD2(Float(metalLayer.drawableSize.width),
                                   Float(metalLayer.drawableSize.height))
            let (resolution, pixelRatio) = ShaderRenderer.miniatureInputs(
                shaderId: model.shaderId, drawable: drawablePx,
                target: target.pixels, targetPixelRatio: target.pixelRatio)

            let frame = ShaderRenderer.FrameInput(
                timeSeconds: time,
                resolutionPixels: resolution,
                pixelRatio: pixelRatio,
                texture: model.texture,
                ambient: model.ambient)
            do {
                try renderer.encode(shaderId: model.shaderId, params: model.params, frame: frame,
                                    renderPass: pass, pixelFormat: metalLayer.pixelFormat,
                                    commandBuffer: commandBuffer)
                commandBuffer.addCompletedHandler { [weak self] _ in
                    DispatchQueue.main.async { self?.frameInFlight = false }
                }
                model.lastRenderedTimeSeconds = time
                commandBuffer.present(drawable)
                commandBuffer.commit()
            } catch {
                frameInFlight = false
                commandBuffer.commit()
            }
        }

        deinit {
            link?.invalidate()
        }
    }
}

/// The iOS preview model — the slim counterpart of ShaderPreviewModel.
@MainActor
final class PreviewModel: ObservableObject {
    let renderer: ShaderRenderer?

    @Published var shaderId: String
    @Published var params: ShaderParams
    @Published var isPlaying = false
    @Published var texture: MTLTexture?
    var ambient: AmbientRenderSpec?
    /// The selected variant's canonical device pixels (miniature target).
    var emulatedPixels: (pixels: SIMD2<Float>, pixelRatio: Float)

    var lastRenderedTimeSeconds: Float = 0
    private var clockBaseMs: Double = 0
    private var startedAt: CFTimeInterval = CACurrentMediaTime()

    init(renderer: ShaderRenderer?, shaderId: String, params: ShaderParams,
         device: DeviceClass) {
        self.renderer = renderer
        self.shaderId = shaderId
        self.params = params
        self.emulatedPixels = Self.target(for: device)
        self.clockBaseMs = params.frame
    }

    static func target(for device: DeviceClass) -> (pixels: SIMD2<Float>, pixelRatio: Float) {
        let px = device.canonicalPixels
        return (SIMD2(Float(px.width), Float(px.height)), device == .ipad ? 2 : 3)
    }

    func resetClock(frameMs: Double) {
        clockBaseMs = frameMs
        startedAt = CACurrentMediaTime()
    }

    func currentTimeSeconds() -> Float {
        guard isPlaying else { return Float(params.frame * 0.001) }
        let elapsed = CACurrentMediaTime() - startedAt
        return Float((clockBaseMs + elapsed * 1000 * params.speed) * 0.001)
    }
}
