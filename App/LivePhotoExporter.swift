import AVFoundation
import CoreGraphics
import ImageIO
import Photos
import ShaderCore
import UIKit
import UniformTypeIdentifiers
import WallshaderModel

/// Live Photo lock-screen wallpapers (C6): a still + paired video sharing a
/// content identifier, saved via PHAssetCreationRequest.
///
/// Lock Screen MOTION eligibility is gated by undocumented structure (DTS:
/// developer.apple.com/forums/thread/798044). A working reference pair was
/// dissected on 2026-07-18 and this exporter mirrors its anatomy exactly:
/// ~1 s HEVC @60 fps (≤1920 tall, BT.709, no audio), the per-frame
/// `live-photo-info` metadata track (verbatim payload + setup data from
/// LivePhotoWallpaperBlobs), and one group at t=0.5 s carrying
/// still-image-time = -1 plus an identity live-photo-still-image-transform.
/// The still is the frame at 0.5 s with the MakerApple "17" identifier.
enum LivePhotoExporter {
    static let videoSeconds = 1.0
    static let fps = 60
    /// The wake animation shows a fixed ~0.5 s slice at the still frame and
    /// SLOWS it (hardware-tested: 1 s and 2 s videos both play the same
    /// short window) — so the export feeds deliberately overdriven motion
    /// and lets iOS supply the slow-down.
    static let speedBoost: Float = 3
    /// The reference's video (and still) height cap; width follows the
    /// screen's aspect, rounded to even.
    static let maxHeight: CGFloat = 1920

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
        let screen = UIScreen.main.nativeBounds.size
        var width = (screen.width / max(1, screen.height) * Self.maxHeight).rounded()
        width -= width.truncatingRemainder(dividingBy: 2)
        let pixels = CGSize(width: width, height: Self.maxHeight)
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

        // The video runs straight through; the still is its 0.5 s frame
        // (matching the reference's still-image-time). Time advances
        // LINEARLY at speedBoost × the shader's max speed: the visible
        // wake slice is short and system-slowed, so it must be packed with
        // motion end to end (an ease-out that settles into the still puts
        // the weakest motion exactly where iOS looks — tested and felt).
        let offscreen = OffscreenRenderer(renderer: renderer)
        let frameCount = Int(videoSeconds * Double(fps))
        let stillFrameIndex = frameCount / 2
        let maxSpeed = Float(ShaderRegistry.shared.schema(for: shaderId)?
            .params.first { $0.name == "speed" }?.max ?? 1)
        let rate = max(1, maxSpeed) * speedBoost
        let renderFrame: @Sendable (Int) throws -> CGImage = { index in
            let t = baseTime + Float(index) / Float(fps) * rate
            return try offscreen.renderImage(
                shaderId: shaderId, params: params,
                pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height),
                pixelRatio: scale, timeSeconds: t,
                texture: texture, ambient: ambient)
        }

        try await Task.detached(priority: .userInitiated) {
            let still = try renderFrame(stillFrameIndex)
            try Self.writeStill(still, to: stillURL, identifier: identifier)
            try await Self.writeVideo(frames: frameCount, size: pixels,
                                      to: videoURL, identifier: identifier,
                                      stillFrameIndex: stillFrameIndex,
                                      renderFrame: renderFrame)
        }.value

        // Verify the pair assembles as a Live Photo BEFORE saving (the C6
        // spike's pass criterion). This must NOT be a post-save PHAsset
        // fetch: reading the library needs NSPhotoLibraryUsageDescription,
        // and under our add-only description TCC aborts the app.
        guard await pairAssemblesAsLivePhoto(stillURL: stillURL, videoURL: videoURL) else {
            try? FileManager.default.removeItem(at: dir)
            throw ExportError.notRecognizedAsLive
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: stillURL, options: nil)
            let videoOptions = PHAssetResourceCreationOptions()
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Assembles the still+video pair with PHLivePhoto (file-based, no
    /// photo-library permission involved). The handler can fire first with
    /// a degraded preview; only the final, non-degraded callback decides.
    private static func pairAssemblesAsLivePhoto(stillURL: URL, videoURL: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var finished = false
            PHLivePhoto.request(withResourceFileURLs: [stillURL, videoURL],
                                placeholderImage: nil, targetSize: .zero,
                                contentMode: .aspectFit) { livePhoto, info in
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                guard !degraded, !finished else { return }
                finished = true
                continuation.resume(returning: livePhoto != nil)
            }
        }
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

    // MARK: - Video (HEVC + the wallpaper-eligibility metadata tracks)

    private static func makeMetadataFormatDescription(from bigEndian: Data) throws -> CMMetadataFormatDescription {
        var desc: CMMetadataFormatDescription?
        let status = bigEndian.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            CMMetadataFormatDescriptionCreateFromBigEndianMetadataDescriptionData(
                allocator: nil,
                bigEndianMetadataDescriptionData: bytes.bindMemory(to: UInt8.self).baseAddress!,
                size: bigEndian.count, flavor: nil, formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { throw ExportError.encodeFailed }
        return desc
    }

    private static func writeVideo(frames: Int, size: CGSize, to url: URL,
                                   identifier: String, stillFrameIndex: Int,
                                   renderFrame: @escaping @Sendable (Int) throws -> CGImage) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Top-level metadata: content identifier ONLY (the reference
        // carries nothing else — no make/model, no vitality).
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
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
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

        // Track: per-frame live-photo-info. The format hint carries the
        // reference's key table + setup data; every sample is the same
        // opaque payload. This track is what makes the pair eligible for
        // Lock Screen motion.
        let infoDesc = try makeMetadataFormatDescription(
            from: LivePhotoWallpaperBlobs.infoTrackFormatDescription)
        let infoInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                           sourceFormatHint: infoDesc)
        infoInput.expectsMediaDataInRealTime = false
        let infoAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: infoInput)
        writer.add(infoInput)

        // Track: still-image-time (-1, the capture convention) + identity
        // still-image transform, one group at t = 0.5 s.
        let stillDesc = try makeMetadataFormatDescription(
            from: LivePhotoWallpaperBlobs.stillTrackFormatDescription)
        let stillInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                            sourceFormatHint: stillDesc)
        stillInput.expectsMediaDataInRealTime = false
        let stillAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: stillInput)
        writer.add(stillInput)

        guard writer.startWriting() else { throw writer.error ?? ExportError.encodeFailed }
        writer.startSession(atSourceTime: .zero)

        let infoItem = AVMutableMetadataItem()
        infoItem.identifier = AVMetadataItem.identifier(
            forKey: "com.apple.quicktime.live-photo-info", keySpace: .quickTimeMetadata)
        // The hint's key table declares this custom data type (conforming
        // to raw); the adaptor requires an exact identifier+dataType match.
        infoItem.dataType = "com.apple.quicktime.com.apple.quicktime.live-photo-info"
        infoItem.value = LivePhotoWallpaperBlobs.infoSamplePayload as NSData
        // The reference's info samples run one frame-duration each,
        // starting three frames in (0.05 s at 60 fps) — copied verbatim.
        for index in 0..<frames {
            let group = AVTimedMetadataGroup(
                items: [infoItem],
                timeRange: CMTimeRange(
                    start: CMTime(value: CMTimeValue(index + 3), timescale: CMTimeScale(fps)),
                    duration: CMTime(value: 1, timescale: CMTimeScale(fps))))
            infoAdaptor.append(group)
        }
        infoInput.markAsFinished()

        let stillTimeItem = AVMutableMetadataItem()
        stillTimeItem.identifier = AVMetadataItem.identifier(
            forKey: "com.apple.quicktime.still-image-time", keySpace: .quickTimeMetadata)
        stillTimeItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        stillTimeItem.value = -1 as NSNumber
        let transformItem = AVMutableMetadataItem()
        transformItem.identifier = AVMetadataItem.identifier(
            forKey: "com.apple.quicktime.live-photo-still-image-transform",
            keySpace: .quickTimeMetadata)
        transformItem.dataType = kCMMetadataBaseDataType_PerspectiveTransformF64 as String
        transformItem.value = [1, 0, 0, 0, 1, 0, 0, 0, 1] as NSArray
        // Marks the exported still's frame (timescale 600, like the
        // reference's 0.5 s = 300/600).
        let stillTicks = CMTimeValue(stillFrameIndex) * 600 / CMTimeValue(fps)
        stillAdaptor.append(AVTimedMetadataGroup(
            items: [stillTimeItem, transformItem],
            timeRange: CMTimeRange(start: CMTime(value: stillTicks, timescale: 600),
                                   duration: CMTime(value: 1, timescale: 600))))
        stillInput.markAsFinished()

        // Feed the video through the writer's pump — with several inputs in
        // the mux, readiness only updates inside requestMediaDataWhenReady.
        final class MuxState: @unchecked Sendable {
            var frameIndex = 0
            var resumed = false
        }
        let state = MuxState()
        let queue = DispatchQueue(label: "com.innovationBox.wallshader.livephoto-mux")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, state.frameIndex < frames, !state.resumed {
                    do {
                        let image = try renderFrame(state.frameIndex)
                        guard let buffer = pixelBuffer(from: image, pool: adaptor.pixelBufferPool,
                                                       size: size) else {
                            throw ExportError.encodeFailed
                        }
                        adaptor.append(buffer, withPresentationTime:
                            CMTime(value: CMTimeValue(state.frameIndex), timescale: CMTimeScale(fps)))
                        state.frameIndex += 1
                    } catch {
                        state.resumed = true
                        input.markAsFinished()
                        cont.resume(throwing: error)
                        return
                    }
                }
                if state.frameIndex >= frames, !state.resumed {
                    state.resumed = true
                    input.markAsFinished()
                    cont.resume()
                }
            }
        }
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
