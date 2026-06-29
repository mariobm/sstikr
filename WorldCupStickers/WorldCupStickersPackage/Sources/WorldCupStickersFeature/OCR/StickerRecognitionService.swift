import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

public enum StickerRecognitionService {
    public static let topRightBadgeRegion = CGRect(x: 0.54, y: 0.70, width: 0.43, height: 0.24)

    public static func recognize(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .right,
        regionOfInterest: CGRect = Self.topRightBadgeRegion
    ) -> StickerScanResult? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.regionOfInterest = regionOfInterest

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
                observation.topCandidates(3).compactMap { candidate in
                    StickerCodeParser.parse(
                        candidate.string,
                        confidence: Double(candidate.confidence)
                    )
                }
            }
            .max { $0.confidence < $1.confidence }
    }
}
