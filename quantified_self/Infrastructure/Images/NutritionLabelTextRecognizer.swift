import Foundation
import ImageIO
import Vision

nonisolated protocol NutritionLabelTextRecognizing: Sendable {
    nonisolated func recognizeText(in images: [NutritionAnalysisImage]) async -> [String]
}

nonisolated struct VisionNutritionLabelTextRecognizer: NutritionLabelTextRecognizing {
    nonisolated func recognizeText(in images: [NutritionAnalysisImage]) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            images.map { Self.recognizeText(in: $0) ?? "" }
        }.value
    }

    private nonisolated static func recognizeText(in image: NutritionAnalysisImage) -> String? {
        guard
            let source = CGImageSourceCreateWithData(image.data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        guard (try? handler.perform([request])) != nil else { return nil }

        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

nonisolated enum NutritionAnalysisImagePreparation {
    private static let maximumUploadDimension = 2_048

    static func prepareForUpload(_ images: [NutritionAnalysisImage]) async -> [NutritionAnalysisImage] {
        await Task.detached(priority: .userInitiated) {
            images.map(prepareForUpload)
        }.value
    }

    private static func prepareForUpload(_ image: NutritionAnalysisImage) -> NutritionAnalysisImage {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { return image }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumUploadDimension,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let destinationData = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                destinationData,
                "public.jpeg" as CFString,
                1,
                nil
            )
        else { return image }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return image }
        return NutritionAnalysisImage(data: destinationData as Data)
    }
}
