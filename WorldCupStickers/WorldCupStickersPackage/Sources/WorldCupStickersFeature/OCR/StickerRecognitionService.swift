import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

public struct StickerRecognitionAttempt: Sendable {
    public let result: StickerScanResult?
    public let effectiveMode: StickerScanMode
    public let faceDetected: Bool

    public init(result: StickerScanResult?, effectiveMode: StickerScanMode, faceDetected: Bool) {
        self.result = result
        self.effectiveMode = effectiveMode
        self.faceDetected = faceDetected
    }
}

public enum StickerRecognitionService {
    public static let topRightBadgeRegion = CGRect(x: 0.43, y: 0.60, width: 0.48, height: 0.22)
    public static let frontNameRegion = CGRect(x: 0.12, y: 0.22, width: 0.76, height: 0.28)
    public static let autoFaceRegion = CGRect(x: 0.14, y: 0.22, width: 0.72, height: 0.62)

    public static func recognize(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .right,
        mode: StickerScanMode = .back,
        backMatcher: StickerCodeCatalogMatcher = .empty,
        frontMatcher: StickerNameMatcher = .empty
    ) -> StickerScanResult? {
        recognizeAttempt(
            in: pixelBuffer,
            orientation: orientation,
            mode: mode,
            backMatcher: backMatcher,
            frontMatcher: frontMatcher
        ).result
    }

    public static func recognizeAttempt(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .right,
        mode: StickerScanMode = .back,
        backMatcher: StickerCodeCatalogMatcher = .empty,
        frontMatcher: StickerNameMatcher = .empty
    ) -> StickerRecognitionAttempt {
        switch mode {
        case .auto:
            let faceDetected = detectFace(in: pixelBuffer, orientation: orientation)
            if faceDetected {
                return StickerRecognitionAttempt(
                    result: recognizeFront(in: pixelBuffer, orientation: orientation, matcher: frontMatcher),
                    effectiveMode: .front,
                    faceDetected: true
                )
            } else {
                return StickerRecognitionAttempt(
                    result: recognizeBack(in: pixelBuffer, orientation: orientation, matcher: backMatcher),
                    effectiveMode: .back,
                    faceDetected: false
                )
            }
        case .back:
            return StickerRecognitionAttempt(
                result: recognizeBack(in: pixelBuffer, orientation: orientation, matcher: backMatcher),
                effectiveMode: .back,
                faceDetected: false
            )
        case .front:
            return StickerRecognitionAttempt(
                result: recognizeFront(in: pixelBuffer, orientation: orientation, matcher: frontMatcher),
                effectiveMode: .front,
                faceDetected: false
            )
        }
    }

    private static func detectFace(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        request.regionOfInterest = autoFaceRegion

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return false
        }

        return request.results?.contains { observation in
            observation.confidence >= 0.55 &&
                observation.boundingBox.width >= 0.045 &&
                observation.boundingBox.height >= 0.045
        } ?? false
    }

    private static func recognizeBack(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        matcher: StickerCodeCatalogMatcher
    ) -> StickerScanResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.regionOfInterest = topRightBadgeRegion
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        return request.results?
            .flatMap { observation in
                observation.topCandidates(5).compactMap { candidate in
                    guard let parsed = StickerCodeParser.parse(
                        candidate.string,
                        confidence: Double(candidate.confidence)
                    ) else {
                        return nil
                    }

                    return matcher.match(parsed)
                }
            }
            .max { $0.confidence < $1.confidence }
    }

    private static func recognizeFront(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        matcher: StickerNameMatcher
    ) -> StickerScanResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.regionOfInterest = frontNameRegion
        request.minimumTextHeight = 0.015

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let lines = request.results?
            .flatMap { observation in
                observation.topCandidates(2).map { candidate in
                    StickerRecognizedTextLine(
                        string: candidate.string,
                        confidence: Double(candidate.confidence)
                    )
                }
            } ?? []

        return matcher.match(lines: lines)
    }
}
