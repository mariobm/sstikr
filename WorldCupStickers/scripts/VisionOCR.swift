import Foundation
import AppKit
import Vision

struct OCRLine: Codable {
    let text: String
    let confidence: Float
}

struct OCRResult: Codable {
    let path: String
    let lines: [OCRLine]
    let error: String?
}

func recognize(path: String) -> OCRResult {
    guard let image = NSImage(contentsOfFile: path),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return OCRResult(path: path, lines: [], error: "Could not load image")
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US", "es-ES", "fr-FR", "de-DE", "pt-BR"]
    request.minimumTextHeight = 0.01

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return OCRResult(path: path, lines: [], error: String(describing: error))
    }

    let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return OCRLine(text: candidate.string, confidence: candidate.confidence)
    }
    return OCRResult(path: path, lines: lines, error: nil)
}

let paths = CommandLine.arguments.dropFirst()
let results = paths.map { recognize(path: String($0)) }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
let data = try encoder.encode(results)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
