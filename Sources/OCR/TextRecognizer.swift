import Foundation
import Vision

enum OCRResult {
    case text(String)
    case qrCode(String)
    case nothing
}

enum TextRecognizer {
    /// Recognize a QR code first; otherwise run OCR. All on-device.
    static func recognize(image: CGImage) async -> OCRResult {
        if let payload = detectQRCode(in: image) {
            return .qrCode(payload)
        }
        let text = recognizeText(in: image)
        return text.isEmpty ? .nothing : .text(text)
    }

    private static func detectQRCode(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.compactMap(\.payloadStringValue).first
    }

    private static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }
}
