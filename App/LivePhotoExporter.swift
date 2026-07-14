import AVFoundation
import CoreGraphics
import ImageIO
import Photos
import ShaderCore
import UIKit
import UniformTypeIdentifiers
import WallshaderModel

/// Live Photo lock-screen wallpapers (C6): a still + a paired ~2.5 s video
/// sharing a content identifier, saved via PHAssetCreationRequest. iOS 17
/// plays these on the Lock Screen on wake. Metadata per Appendix B:
/// MakerApple "17" on the still; com.apple.quicktime.content.identifier +
/// a still-image-time metadata track on the video.
enum LivePhotoExporter {
    static let loopSeconds = 2.5
    static let fps = 30

    @MainActor
    static func canExportLive(model: EditorModel) -> Bool {
        guard let doc = model.document else { return false }
        return doc.shaderIsAnimatable
            && (model.editingVariant?.animated ?? false)
            && model.selectedDevice == AppModel.currentDevice
    }

    @MainActor
    static func saveLiveWallpaper(model: EditorModel) async throws {
        guard let renderer = model.app.renderer,
              let doc = model.document, let shaderId = doc.shaderId else {
            throw ExportError.notRenderable
        }
        model.flushPendingWriteback()
        let params = model.preview.params
        let texture = model.preview.texture
        let pixels = UIScreen.main.nativeBounds.size
        let scale = Float(UIScreen.main.scale)
        let ambient = model.preview.ambient
        let baseTime = model.preview.lastRenderedTimeSeconds

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photosDenied
        }

        let identifier = UUID().uuidString
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stillURL = dir.appendingPathComponent("still.heic")
        let videoURL = dir.appendingPathComponent("video.mov")

        // Render the frames on a background task; frames crossfade the tail
        // into the head so the loop is seamless (Appendix B).
        let offscreen = OffscreenRenderer(renderer: renderer)
        let frameCount = Int(loopSeconds * Double(fps))
        let renderFrame: @Sendable (Int) throws -> CGImage = { index in
            let t = baseTime + Float(index) / Float(fps)
            let frame = try offscreen.renderImage(
                shaderId: shaderId, params: params,
                pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
                pixelRatio: scale, timeSeconds: t,
                texture: texture, ambient: ambient)
            let fadeFrames = Int(0.4 * Double(fps))
            let fadeStart = frameCount - fadeFrames
            guard index >= fadeStart else { return frame }
            // Crossfade toward the loop's first frame.
            let headTime = baseTime + Float(index - fadeStart) / Float(fps) * 0
            let head = try offscreen.renderImage(
                shaderId: shaderId, params: params,
                pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
                pixelRatio: scale, timeSeconds: headTime,
                texture: texture, ambient: ambient)
            let alpha = CGFloat(index - fadeStart + 1) / CGFloat(fadeFrames + 1)
            return Self.blend(frame, head, alpha: alpha) ?? frame
        }

        try await Task.detached(priority: .userInitiated) {
            let still = try renderFrame(0)
            try Self.writeStill(still, to: stillURL, identifier: identifier)
            try await Self.writeVideo(frames: frameCount, size: pixels,
                                      to: videoURL, identifier: identifier,
                                      renderFrame: renderFrame)
        }.value

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: stillURL, options: nil)
            let videoOptions = PHAssetResourceCreationOptions()
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
        }

        // Verify the saved asset actually reports .photoLive (the C6 spike's
        // pass criterion); stale-format pairs silently save as stills.
        let fetch = PHAsset.fetchAssets(with: .image, options: {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 1
            return options
        }())
        if let newest = fetch.firstObject, !newest.mediaSubtypes.contains(.photoLive) {
            throw ExportError.notRecognizedAsLive
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Still (HEIC with MakerApple content identifier)

    private static func writeStill(_ image: CGImage, to url: URL, identifier: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw ExportError.encodeFailed
        }
        let makerApple: [String: Any] = ["17": identifier]
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: makerApple,
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodeFailed }
    }

    // MARK: - Video (HEVC, content identifier + still-image-time track)

    private static func writeVideo(frames: Int, size: CGSize, to url: URL,
                                   identifier: String,
                                   renderFrame: @Sendable (Int) throws -> CGImage) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Top-level content identifier.
        let idItem = AVMutableMetadataItem()
        idItem.key = "com.apple.quicktime.content.identifier" as NSString
        idItem.keySpace = AVMetadataKeySpace.quickTimeMetadata
        idItem.value = identifier as NSString
        idItem.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [idItem]

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)

        // Timed metadata track marking the still frame (t≈0 convention).
        let stillSpec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String,
        ]
        var formatDescription: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [stillSpec] as CFArray,
            formatDescriptionOut: &formatDescription)
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                               sourceFormatHint: formatDescription)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        writer.add(metadataInput)

        guard writer.startWriting() else { throw writer.error ?? ExportError.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        // Still-image-time at t=0.
        let stillItem = AVMutableMetadataItem()
        stillItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillItem.keySpace = AVMetadataKeySpace.quickTimeMetadata
        stillItem.value = 0 as NSNumber
        stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        let group = AVTimedMetadataGroup(
            items: [stillItem],
            timeRange: CMTimeRange(start: .zero,
                                   duration: CMTime(value: 1, timescale: CMTimeScale(fps))))
        metadataAdaptor.append(group)
        metadataInput.markAsFinished()

        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            let image = try renderFrame(index)
            guard let buffer = pixelBuffer(from: image, pool: adaptor.pixelBufferPool,
                                           size: size) else {
                throw ExportError.encodeFailed
            }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.encodeFailed
        }
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool?,
                                    size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    private static func blend(_ a: CGImage, _ b: CGImage, alpha: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: a.width, height: a.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        context.draw(a, in: rect)
        context.setAlpha(alpha)
        context.draw(b, in: rect)
        return context.makeImage()
    }

    enum ExportError: LocalizedError {
        case notRenderable
        case photosDenied
        case encodeFailed
        case notRecognizedAsLive

        var errorDescription: String? {
            switch self {
            case .notRenderable: return "This wallpaper can't be rendered right now."
            case .photosDenied: return "Allow Wallshader to add to your photo library in Settings > Privacy."
            case .encodeFailed: return "Building the Live Photo failed."
            case .notRecognizedAsLive: return "Photos didn't recognize the pair as a Live Photo."
            }
        }
    }
}
