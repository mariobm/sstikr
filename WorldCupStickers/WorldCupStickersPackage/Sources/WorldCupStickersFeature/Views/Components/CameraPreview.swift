import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocusPoint: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        let recognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFocusPoint: onFocusPoint)
    }
}

@MainActor
final class Coordinator: NSObject {
    private let onFocusPoint: (CGPoint, CGPoint) -> Void

    init(onFocusPoint: @escaping (CGPoint, CGPoint) -> Void) {
        self.onFocusPoint = onFocusPoint
    }

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view as? PreviewView else { return }
        let viewPoint = recognizer.location(in: view)
        let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)
        onFocusPoint(devicePoint, viewPoint)
    }
}

@MainActor
final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("PreviewView must use AVCaptureVideoPreviewLayer.")
        }
        return layer
    }
}
