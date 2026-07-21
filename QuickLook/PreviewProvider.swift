import QuickLook
import UIKit
import WallshaderModel

/// A tapped .wallshader (Messages, Mail, Files long-press) shows the
/// wallpaper's REAL render. View-based QLPreviewingController — the
/// data-based provider shape silently fell back to the generic document
/// card on hardware (same rejection the Mac reported out loud).
final class PreviewViewController: UIViewController, QLPreviewingController {
    private let imageView = UIImageView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
    }

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let data = try Data(contentsOf: url)
            let image = try WallshaderPreviewer.previewImage(fileData: data)
            imageView.image = UIImage(cgImage: image)
            preferredContentSize = CGSize(width: image.width / 3, height: image.height / 3)
            handler(nil)
        } catch {
            Self.diag("FAIL \(url.lastPathComponent): \(error)")
            handler(error)
        }
    }

    /// Field diagnosis into the extension's own container tmp — pull with
    /// devicectl (domain-identifier com.innovationBox.wallshader.quicklook).
    private static func diag(_ line: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-diag.txt")
        let stamped = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
