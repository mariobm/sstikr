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
    public private(set) var statusMessage = "Align either side of the sticker inside the guide."
    public private(set) var availableLenses: [CameraLens] = []
    public private(set) var currentLens: CameraLens = .wide
    public private(set) var scanMode: StickerScanMode = .auto
    public private(set) var activeScanMode: StickerScanMode = .back

    private let videoOutput = AVCaptureVideoDataOutput()
    private nonisolated let recognitionState = CameraRecognitionState()
    private let captureQueue = DispatchQueue(label: "WorldCupStickers.CameraScanner.capture")
    private var currentInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var detectionPaused = false
    private var previousCandidateID: String?
    private var candidateStreak = 0
    private var autoFrontStreak = 0
    private var autoBackStreak = 0

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
        statusMessage = "\(currentLens.title) active. \(scanMode.alignmentMessage)"
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
        resetAutoStreaks()
        detectionPaused = false
        statusMessage = "\(currentLens.title) active. Ready for the next \(scanMode.title.lowercased()) scan."
    }

    public func resetForScreenEntry() {
        stableResult = nil
        lastCandidate = nil
        previousCandidateID = nil
        candidateStreak = 0
        if scanMode == .auto {
            activeScanMode = .back
        }
        resetAutoStreaks()
        detectionPaused = false
        statusMessage = "\(currentLens.title) active. \(scanMode.alignmentMessage)"
    }

    public func discardStableResult(message: String) {
        stableResult = nil
        lastCandidate = nil
        previousCandidateID = nil
        candidateStreak = 0
        resetAutoStreaks()
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

    public func setScanMode(_ mode: StickerScanMode) {
        guard mode != scanMode else { return }
        scanMode = mode
        recognitionState.setMode(mode)
        if mode != .auto {
            activeScanMode = mode
        } else {
            activeScanMode = .back
        }
        resetAutoStreaks()
        discardStableResult(message: mode.alignmentMessage)
    }

    public func updateCatalog(stickers: [StickerDefinition]) {
        recognitionState.setBackMatcher(StickerCodeCatalogMatcher(stickers: stickers))
        recognitionState.setFrontMatcher(StickerNameMatcher(stickers: stickers))
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

    private func consume(_ attempt: StickerRecognitionAttempt) {
        guard !detectionPaused else { return }

        if scanMode == .auto {
            updateAutoMode(from: attempt)
        }

        guard let result = attempt.result else {
            previousCandidateID = nil
            candidateStreak = 0
            lastCandidate = nil
            return
        }
        consume(result)
    }

    private func consume(_ result: StickerScanResult) {
        activeScanMode = result.scanMode
        lastCandidate = result
        let candidateID = "\(result.scanMode.rawValue)-\(result.id)"
        if previousCandidateID == candidateID {
            candidateStreak += 1
        } else {
            previousCandidateID = candidateID
            candidateStreak = 1
        }

        statusMessage = "\(result.scanMode.title) matched \(result.displayCode). Hold steady."
        if candidateStreak >= 2 {
            stableResult = result
            statusMessage = "Confirm \(result.displayCode)."
        }
    }

    private func updateAutoMode(from attempt: StickerRecognitionAttempt) {
        guard attempt.effectiveMode != .auto else { return }

        if attempt.effectiveMode == .front {
            autoFrontStreak += 1
            autoBackStreak = 0
            guard autoFrontStreak >= 2 else { return }
        } else {
            autoBackStreak += 1
            autoFrontStreak = 0
            guard autoBackStreak >= 3 else { return }
        }

        guard activeScanMode != attempt.effectiveMode else { return }
        activeScanMode = attempt.effectiveMode
        previousCandidateID = nil
        candidateStreak = 0
        lastCandidate = nil

        statusMessage = attempt.faceDetected
            ? "Face detected. Scanning the player name."
            : "Scanning the back code badge."
    }

    private func resetAutoStreaks() {
        autoFrontStreak = 0
        autoBackStreak = 0
    }
}

extension CameraScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let recognitionSnapshot = recognitionState.snapshot()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let attempt = StickerRecognitionService.recognizeAttempt(
                in: pixelBuffer,
                mode: recognitionSnapshot.mode,
                backMatcher: recognitionSnapshot.backMatcher,
                frontMatcher: recognitionSnapshot.frontMatcher
        )

        guard attempt.result != nil || recognitionSnapshot.mode == .auto else { return }

        Task { @MainActor [weak self] in
            self?.consume(attempt)
        }
    }
}

private final class CameraRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var mode: StickerScanMode = .auto
    private var backMatcher: StickerCodeCatalogMatcher = .empty
    private var frontMatcher: StickerNameMatcher = .empty

    func setMode(_ mode: StickerScanMode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    func setFrontMatcher(_ frontMatcher: StickerNameMatcher) {
        lock.lock()
        self.frontMatcher = frontMatcher
        lock.unlock()
    }

    func setBackMatcher(_ backMatcher: StickerCodeCatalogMatcher) {
        lock.lock()
        self.backMatcher = backMatcher
        lock.unlock()
    }

    func snapshot() -> (
        mode: StickerScanMode,
        backMatcher: StickerCodeCatalogMatcher,
        frontMatcher: StickerNameMatcher
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (mode, backMatcher, frontMatcher)
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
