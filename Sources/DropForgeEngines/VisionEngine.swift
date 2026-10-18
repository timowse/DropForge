import Foundation
import Vision
import DropForgeCore

/// On-device detection with the Vision framework. Nothing leaves the Mac.
public struct VisionEngine: Sendable {
    public init() {}

    public struct Code: Sendable, Hashable {
        public let symbology: String
        public let payload: String
    }

    public func codes(in image: CGImage) throws -> [Code] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap { obs in
            guard let payload = obs.payloadStringValue, seen.insert(payload).inserted else { return nil }
            let name = obs.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
            return Code(symbology: name, payload: payload)
        }
    }

    /// Vision boxes are normalised with a bottom-left origin; DropForge uses top-left.
    static func unitRect(_ box: CGRect, padding: Double = 0.01) -> UnitRect {
        let x = max(0, box.minX - padding), y = max(0, 1 - box.maxY - padding)
        let w = min(1 - x, box.width + 2 * padding), h = min(1 - y, box.height + 2 * padding)
        return UnitRect(x: x, y: y, width: w, height: h)
    }

    public func faces(in image: CGImage) throws -> [UnitRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { Self.unitRect($0.boundingBox, padding: 0.02) }
    }

    public func textRegions(in image: CGImage) throws -> [UnitRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { Self.unitRect($0.boundingBox, padding: 0.004) }
    }
}
