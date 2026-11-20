import SwiftUI
import VisionKit

struct DocumentScanner: UIViewControllerRepresentable {
    let completion: (Result<VaultDocument, Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let completion: (Result<VaultDocument, Error>?) -> Void
        init(completion: @escaping (Result<VaultDocument, Error>?) -> Void) { self.completion = completion }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(.failure(error))
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { completion(nil); return }
            guard scan.pageCount <= 16 else { completion(.failure(IntakeError.tooManyPages)); return }
            let sheet = CGRect(x: 0, y: 0, width: 595, height: 842)
            let data = UIGraphicsPDFRenderer(bounds: sheet).pdfData { ctx in
                for index in 0..<scan.pageCount {
                    autoreleasepool {
                        ctx.beginPage()
                        let image = scan.imageOfPage(at: index)
                        let factor = min(sheet.width / image.size.width, sheet.height / image.size.height)
                        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                        let rect = CGRect(x: (sheet.width - size.width) / 2, y: (sheet.height - size.height) / 2,
                                          width: size.width, height: size.height)
                        image.draw(in: rect)
                    }
                }
            }
            completion(Result { try VaultDocument(bytes: data, mime: "application/pdf") })
        }
    }
}
