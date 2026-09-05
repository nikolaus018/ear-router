import SwiftUI
import VisionKit

/// The system's document camera — the one that finds the edges of a sheet of
/// paper, straightens it and lets the driver keep shooting page after page in
/// one session.
///
/// Not a plain camera. The input here is an A4 page of dense table text
/// photographed one-handed on a van seat, and the two things that decide
/// whether OCR reads it are perspective and crop — exactly the two this
/// controller fixes before it hands the image back. It also does "take
/// multiple ones" natively: a five-page list is five shutter taps and one
/// Sichern, with a retake button for the one that came out blurred.
///
/// Pages come back as JPEG `Data` rather than `UIImage`, because that is what
/// crosses to the OCR unambiguously: `jpegData` bakes the orientation into the
/// pixels, so nothing downstream has to know which way the phone was held.
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([Data]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([Data]) -> Void
        private let onCancel: () -> Void

        init(onFinish: @escaping ([Data]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // 0.9 rather than the usual 0.8: the smallest text on the page is
            // the Hinweis column at about 7pt, and JPEG artefacts around
            // characters that small are the difference between "vdt" and "vdl".
            let pages = (0..<scan.pageCount).compactMap {
                scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9)
            }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController, didFailWithError error: any Error
        ) {
            // Treated as a cancellation on purpose. The scanner has already
            // shown the driver whatever went wrong; a second alert behind it
            // would only be this app repeating it.
            onCancel()
        }
    }
}
