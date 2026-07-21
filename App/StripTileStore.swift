import CoreGraphics
import Foundation
import ShaderCore
import WallshaderModel

/// Shader-strip tiles (C2). Procedural tiles render each shader's default
/// look; image-shader tiles render from the USER'S OWN photo — the Mac
/// Studio's signature strip behavior, keyed by the photo's cache key.
@MainActor
final class StripTileStore: ObservableObject {
    static let shared = StripTileStore()

    private var cache: [String: CGImage] = [:]
    private var inFlight: Set<String> = []

    static func orderedIds(for kind: WallpaperDocument.Kind) -> [String] {
        let matching = ShaderRegistry.shared.orderedIds.filter { id in
            let needsTexture = ShaderRegistry.shared.schema(for: id)?.needsTexture ?? false
            return (kind == .imageBased) == needsTexture
        }
        // Mac parity (CenterEditorView): animated shaders lead for
        // shader documents, stills lead for photo documents; stable
        // within each group so the registry order holds.
        func isAnimated(_ id: String) -> Bool {
            ShaderRegistry.shared.schema(for: id)?.animated ?? false
        }
        let animated = matching.filter(isAnimated)
        let still = matching.filter { !isAnimated($0) }
        return kind == .imageBased ? still + animated : animated + still
    }

    static func displayName(_ id: String) -> String {
        id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    func tile(for shaderId: String, model: EditorModel) -> CGImage? {
        guard let schema = ShaderRegistry.shared.schema(for: shaderId) else { return nil }
        let photoKey = schema.needsTexture ? (model.document?.sourceImageCacheKey ?? "none") : "procedural"
        let key = "\(shaderId)|\(photoKey)"
        if let hit = cache[key] { return hit }
        guard !inFlight.contains(key), let renderer = model.app.renderer else { return nil }
        if schema.needsTexture && model.preview.texture == nil { return nil }
        inFlight.insert(key)

        var params = ShaderParams(schema: schema)
        if schema.needsTexture {
            params.fillCanvasForThumbnail()
            // Match the Mac tiles' legibility tweaks where they exist.
            if shaderId == "image-dithering" {
                params["originalColors"] = .bool(true)
                params["colorSteps"] = .number(4)
            }
            if shaderId == "water" { params["size"] = .number(0.5) }
        }
        let texture = schema.needsTexture ? model.preview.texture : nil
        let box = RendererBox(renderer: renderer)
        Task.detached(priority: .utility) { [weak self] in
            let image: CGImage?
            do {
                image = try box.offscreen.renderImage(
                    shaderId: shaderId, params: params,
                    pixelWidth: 192, pixelHeight: 120, pixelRatio: 2,
                    timeSeconds: 0, texture: texture)
            } catch {
                print("strip-tile FAIL \(shaderId): \(error)")
                image = nil
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(key)
                if let image {
                    self.cache[key] = image
                    self.objectWillChange.send()
                }
            }
        }
        return nil
    }

    private struct RendererBox: @unchecked Sendable {
        let offscreen: OffscreenRenderer
        init(renderer: ShaderRenderer) { offscreen = OffscreenRenderer(renderer: renderer) }
    }
}
