import UIKit
import CallKit

/// Presentation only; does not instantiate/activate a provider or start a call.
@MainActor enum VoicestackCallKitPresentation {
    static let iconPoints: CGFloat = 40
    static let symbolName = "waveform" // Default glyph; a future principal preference may replace it.
    static func configuration(scale requestedScale: CGFloat? = nil) -> CXProviderConfiguration {
        let config = CXProviderConfiguration(localizedName: "Voicestack")
        config.maximumCallGroups = 1; config.maximumCallsPerCallGroup = 1
        config.supportsVideo = false; config.includesCallsInRecents = false
        config.supportedHandleTypes = [.generic]
        config.ringtoneSound = nil // Standard CallKit ringtone; never overrides Silent/Focus.
        config.iconTemplateImageData = icon(scale: requestedScale ?? UIScreen.main.scale)
        return config
    }
    static func icon(scale requestedScale: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = requestedScale >= 3 ? 3 : 2
        format.opaque = false; format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: iconPoints, height: iconPoints), format: format)
        let symbol = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let drawn = renderer.image { _ in
            if let symbol {
                let factor = min(30 / symbol.size.width, 30 / symbol.size.height)
                let size = CGSize(width: symbol.size.width * factor, height: symbol.size.height * factor)
                symbol.draw(in: CGRect(x: (iconPoints - size.width) / 2, y: (iconPoints - size.height) / 2, width: size.width, height: size.height))
            }
        }
        guard let mask = drawn.cgImage else { return nil }
        // Preserve only symbol alpha. CallKit wants a white template, not the
        // symbol renderer's palette/hierarchical/color-space RGB values.
        return renderer.image { context in
            let bounds = CGRect(x: 0, y: 0, width: iconPoints, height: iconPoints)
            context.cgContext.clip(to: bounds, mask: mask)
            UIColor.white.setFill(); context.fill(bounds)
        }.pngData()
    }
}
