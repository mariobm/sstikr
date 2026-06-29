@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class CameraScanner: NSObject {
    public let session = AVCaptureSession()
    public private(set) var authorizationState: CameraAuthorizationState = .notDetermined
    public private(set) var stableResult: StickerScanResult?
    public private(set) var lastCandidate: StickerScanResult?
    public private(set) var statusMessage = "Align the back of the sticker inside the guide."
    public private(set) var availableLenses: [CameraLens] = []
    public private(set) var currentLens: CameraLens = .wide

    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "WorldCupStickers.CameraScanner.capture")
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var detectionPaused = false
    private var previousCandidateID: String?
    private var candidateStreak = 0

    public func configure() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationState = granted ? .authorized : .denied
        case .denied:
            authorizationState = .denied
        case .restricted:
            authorizationState = .restricted
        @unknown default:
            authorizationState = .denied
        }

        guard authorizationState == .authorized, !isConfigured else { return }
        configureSession()
    }

    public func start() {
        guard authorizationState == .authorized, isConfigured else { return }
        detectionPaused = false
        statusMessage = "\(currentLens.title) active. Tap the badge to focus."
        let session = session
        captureQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    public func stop() {
        let session = session
        captureQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    public func pauseDetections() {
        detectionPaused = true
    }

    public func resumeDetections() {
        stableResult = nil
        lastCandidate = nil
        previousCandidateID = nil
        candidateStreak = 0
        detectionPaused = false
        statusMessage = "\(currentLens.title) active. Ready for the next sticker."
    }

    public func discardStableResult(message: String) {
        stableResult = nil
        lastCandidate = nil
        previousCandidateID = nil
        candidateStreak = 0
        detectionPaused = false
        statusMessage = message
    }

    public func switchToNextLens() {
        guard authorizationState == .authorized, availableLenses.count > 1 else { return }
        let nextLens: CameraLens
        if let currentIndex = availableLenses.firstIndex(of: currentLens) {
            nextLens = availableLenses[(currentIndex + 1) % availableLenses.count]
        } else {
            nextLens = availableLenses[0]
        }

        replaceInput(with: nextLens)
        resumeDetections()
    }

    public func focus(at devicePoint: CGPoint) {
        guard let device = currentInput?.device else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }

            statusMessage = "Focusing on the tapped badge area."
        } catch {
            statusMessage = "Could not focus there. Try the lens button."
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        availableLenses = CameraLens.availableBackLenses()
        let preferredLens: CameraLens = availableLenses.contains(.ultraWide) ? .ultraWide : .wide
        guard addInput(for: preferredLens) else {
            authorizationState = .unavailable
            statusMessage = "Back camera is unavailable."
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(videoOutput) else {
            authorizationState = .unavailable
            statusMessage = "Camera output is unavailable."
            return
        }

        session.addOutput(videoOutput)
        isConfigured = true
    }

    @discardableResult
    private func addInput(for lens: CameraLens) -> Bool {
        guard let device = lens.device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return false
        }

        session.addInput(input)
        currentInput = input
        currentLens = lens
        configureCloseFocusDefaults(for: device)
        return true
    }

    private func replaceInput(with lens: CameraLens) {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }

        if !addInput(for: lens), !addInput(for: currentLens) {
            authorizationState = .unavailable
            statusMessage = "Could not switch cameras."
        }
    }

    private func configureCloseFocusDefaults(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
        } catch {
            statusMessage = "Camera focus configuration failed."
        }
    }

    private func consume(_ result: StickerScanResult) {
        guard !detectionPaused else { return }

        lastCandidate = result
        if previousCandidateID == result.id {
            candidateStreak += 1
        } else {
            previousCandidateID = result.id
            candidateStreak = 1
        }

        statusMessage = "Detected \(result.displayCode). Hold steady."
        if candidateStreak >= 2 {
            stableResult = result
            statusMessage = "Confirm \(result.displayCode)."
        }
    }
}

extension CameraScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let result = StickerRecognitionService.recognize(in: pixelBuffer) else {
            return
        }

        Task { @MainActor [weak self] in
            self?.consume(result)
        }
    }
}

public enum CameraAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

public enum CameraLens: String, CaseIterable, Identifiable, Sendable {
    case ultraWide
    case wide

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ultraWide:
            "0.5x close-up"
        case .wide:
            "1x camera"
        }
    }

    public var buttonTitle: String {
        switch self {
        case .ultraWide:
            "0.5x"
        case .wide:
            "1x"
        }
    }

    fileprivate var device: AVCaptureDevice? {
        AVCaptureDevice.default(deviceType, for: .video, position: .back)
    }

    private var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide:
            .builtInUltraWideCamera
        case .wide:
            .builtInWideAngleCamera
        }
    }

    fileprivate static func availableBackLenses() -> [CameraLens] {
        CameraLens.allCases.filter { $0.device != nil }
    }
}
