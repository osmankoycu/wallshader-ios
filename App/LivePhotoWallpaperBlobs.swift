import Foundation

/// Byte-exact blobs from a REFERENCE Live Photo pair that iOS accepts as a
/// motion wallpaper (dissected 2026-07-18 from a working App Store app's
/// output; its setup data reveals it was itself copied from an iPhone OS
/// 17.0 capture). The Lock Screen's wallpaper analysis requires the
/// undocumented per-frame `live-photo-info` metadata track and the
/// still-image-time/-transform group — Photos accepts these verbatim.
enum LivePhotoWallpaperBlobs {
    /// Big-endian CMMetadataFormatDescription for the per-frame
    /// `com.apple.quicktime.live-photo-info` track (carries the
    /// LivePhotoMetadataSetupData bplist).
    static let infoTrackFormatDescription = Data(hex:
        "0000021b6d656278000000000000ffff0000020b6b65797300000203000000010000002f6b65" +
        "79646d647461636f6d2e6170706c652e717569636b74696d652e6c6976652d70686f746f2d69" +
        "6e666f000000436474797000000001636f6d2e6170706c652e717569636b74696d652e636f6d" +
        "2e6170706c652e717569636b74696d652e6c6976652d70686f746f2d696e666f000001717365" +
        "7475000001596366677662706c6973743030d301020304050c5f10214c69766550686f746f4d" +
        "6574616461746153657475704461746156657273696f6e5d53797374656d56657273696f6e5f" +
        "10114672616d65776f726b56657273696f6e731001d3060708090a0b5f101350726f64756374" +
        "4275696c6456657273696f6e5b50726f647563744e616d655e50726f6475637456657273696f" +
        "6e583231413532373768596950686f6e65204f535431372e30d40d0e0f10111213145a436f72" +
        "654d6f74696f6e5d434d43617074757265436f72655e48313049535053657276696365735943" +
        "6f72654d6564696158323836382e302e32573434362e352e335432302e325e333034352e3639" +
        "2e322e31312e340008000f0033004100550057005e00740080008f009800a200a700b000bb00" +
        "c900d800e200eb00f300f8000000000000020100000000000000150000000000000000000000" +
        "00000001070000001064696d7300000780000005a00000001863747073000000106474797000" +
        "00000000000000"
    )!

    /// One frame's `live-photo-info` payload (constant across frames).
    static let infoSamplePayload = Data(hex:
        "03000000bdc36d3ce3b5eb6d800000007b80ad425a2d64410a08cb3e7feea6bd79e9f63f0000" +
        "80400400ff00000000000000000000000000000000000000000007000000525e873ee66e52bf" +
        "1b2a6ac4d37862bf761ed23dde3f8ec313f52f39b2f04439ff309dbf1a17f1ed1b0700002067" +
        "96ed1b07000000000000000000000000000000000000"
    )!

    /// Big-endian CMMetadataFormatDescription for the still-image-time +
    /// live-photo-still-image-transform track.
    static let stillTrackFormatDescription = Data(hex:
        "000000b86d656278000000000000ffff000000a86b6579730000004800000001000000306b65" +
        "79646d647461636f6d2e6170706c652e717569636b74696d652e7374696c6c2d696d6167652d" +
        "74696d65000000106474797000000000000000410000005800000002000000406b6579646d64" +
        "7461636f6d2e6170706c652e717569636b74696d652e6c6976652d70686f746f2d7374696c6c" +
        "2d696d6167652d7472616e73666f726d00000010647479700000000000000053"
    )!
}

extension Data {
    init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
