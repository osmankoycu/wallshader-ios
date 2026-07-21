import ShaderCore
import WallshaderModel
import WallshaderStoreCore
import XCTest

/// The shared packages exercised from the iOS side (C10): registry loads
/// its bundled schemas, variant derivation behaves, documents round-trip
/// through the codec, and the store policy matches the Mac.
final class ModelIntegrationTests: XCTestCase {
    func testRegistryLoadsAllSchemas() {
        let ids = ShaderRegistry.shared.orderedIds
        XCTAssertGreaterThanOrEqual(ids.count, 26, "all ported shaders present")
        for id in ids {
            XCTAssertNotNil(ShaderRegistry.shared.schema(for: id), "schema missing for \(id)")
        }
    }

    @MainActor
    func testDocumentDecodesV2AndDerivesVariants() throws {
        // A v1.0-era (version 2) document JSON: no variants key at all.
        let json = """
        {"version":2,"id":"1B675E2C-6F71-4F1A-9B39-111111111111",
         "name":"Legacy","kind":"imageBased","shaderId":"halftone-dots",
         "params":{"fit":"cover","scale":1.4,"offsetX":0.2},
         "sourceImage":"images/x.png","animated":false,
         "createdAt":"2026-01-01T00:00:00Z","modifiedAt":"2026-01-01T00:00:00Z"}
        """
        let doc = try WallpaperLibrary.makeDecoder()
            .decode(WallpaperDocument.self, from: Data(json.utf8))
        XCTAssertNil(doc.variants, "v2 documents are desktop-variant-only")
        XCTAssertFalse(doc.isCustomized(.iphone))
        let variant = doc.resolvedVariant(for: .iphone, imageAspect: 1.5)
        XCTAssertEqual(variant.params["scale"], .number(1.4), "scale carries over")
        XCTAssertNotNil(variant.params["offsetX"], "re-framed offsets present")
    }

    @MainActor
    func testVariantCustomizationRoundTripsThroughCodec() throws {
        var doc = WallpaperDocument.blank(name: "Test")
        doc.kind = .procedural
        doc.shaderId = "mesh-gradient"
        var variant = doc.desktopVariant
        variant.params["scale"] = .number(2.5)
        doc.setVariant(variant, for: .iphone)

        let data = try WallpaperLibrary.makeEncoder().encode(doc)
        let decoded = try WallpaperLibrary.makeDecoder()
            .decode(WallpaperDocument.self, from: data)
        XCTAssertTrue(decoded.isCustomized(.iphone))
        XCTAssertEqual(decoded.storedVariant(for: .iphone)?.params["scale"], .number(2.5))
        XCTAssertEqual(decoded.version, 3)
    }

    func testFreeLimitPolicyMatchesMac() {
        XCTAssertEqual(StoreService.freeDocumentLimit, 7)
        XCTAssertEqual(StoreService.proProductID, "com.innovationBox.wallshader.pro")
    }

    @MainActor
    func testCanonicalAspectsMatchTheDeviceExperience() {
        // iPhone is portrait; iPad and desktop are LANDSCAPE — the iPad
        // app is landscape-only by design (2026-07-21).
        XCTAssertLessThan(DeviceClass.iphone.canonicalAspect, 1)
        XCTAssertGreaterThan(DeviceClass.ipad.canonicalAspect, 1)
        XCTAssertGreaterThan(DeviceClass.desktop.canonicalAspect, 1)
    }
}
