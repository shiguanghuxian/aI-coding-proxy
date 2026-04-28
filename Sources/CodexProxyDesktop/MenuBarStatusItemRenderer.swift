#if os(macOS)
import AppKit

@MainActor
final class MenuBarStatusItemRenderer {
    struct RenderResult {
        let image: NSImage
        let iconFrame: NSRect
        let primaryTextFrame: NSRect
        let secondaryTextFrame: NSRect
        let visibleContentRect: NSRect

        var textBlockFrame: NSRect {
            self.primaryTextFrame.union(self.secondaryTextFrame)
        }
    }

    private enum RenderContent: Hashable {
        case tokenUsage(primaryLine: String, secondaryLine: String)
        case iconOnly(sideLengthBucket: Int)
    }

    private struct CacheKey: Hashable {
        let content: RenderContent
        let symbolName: String
        let foregroundColorKey: ForegroundColorKey
        let scaleBucket: Int
    }

    private struct ForegroundColorKey: Hashable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private enum Metrics {
        static let horizontalPadding: CGFloat = 4
        static let verticalPadding: CGFloat = 1
        static let iconToTextSpacing: CGFloat = 5
        static let lineSpacing: CGFloat = 0
        static let iconSize = NSSize(width: 18, height: 18)
        static let anchorOutset = CGSize(width: 1, height: 1)
        static let symbolPointSize: CGFloat = 18
        static let symbolWeight: NSFont.Weight = .semibold
        static let symbolScale: NSImage.SymbolScale = .large
    }

    private var cache: [CacheKey: RenderResult] = [:]

    func render(
        presentation: DesktopAppModel.MenuBarTokenUsagePresentation,
        symbolName: String,
        appearance: NSAppearance,
        foregroundColor: NSColor,
        isHighlighted _: Bool,
        scale: CGFloat
    ) -> RenderResult {
        self.render(
            content: .tokenUsage(
                primaryLine: presentation.primaryLine,
                secondaryLine: presentation.secondaryLine
            ),
            symbolName: symbolName,
            appearance: appearance,
            foregroundColor: foregroundColor,
            scale: scale
        )
    }

    func renderIconOnly(
        symbolName: String,
        appearance: NSAppearance,
        foregroundColor: NSColor,
        isHighlighted _: Bool,
        scale: CGFloat,
        sideLength: CGFloat
    ) -> RenderResult {
        self.render(
            content: .iconOnly(sideLengthBucket: Int((sideLength * 100).rounded())),
            symbolName: symbolName,
            appearance: appearance,
            foregroundColor: foregroundColor,
            scale: scale
        )
    }

    private func render(
        content: RenderContent,
        symbolName: String,
        appearance: NSAppearance,
        foregroundColor: NSColor,
        scale: CGFloat
    ) -> RenderResult {
        let key = CacheKey(
            content: content,
            symbolName: symbolName,
            foregroundColorKey: self.foregroundColorKey(for: foregroundColor),
            scaleBucket: Int((scale * 100).rounded())
        )
        if let cached = self.cache[key] {
            return cached
        }

        let layout = self.layout(for: content)

        guard
            let representation = self.bitmapRepresentation(size: layout.size, scale: scale),
            let context = NSGraphicsContext(bitmapImageRep: representation)
        else {
            let fallbackImage = self.makeFallbackImage(
                layout: layout,
                content: content,
                symbolName: symbolName,
                appearance: appearance,
                foregroundColor: foregroundColor
            )
            let fallbackResult = RenderResult(
                image: fallbackImage,
                iconFrame: layout.iconFrame,
                primaryTextFrame: layout.primaryTextFrame,
                secondaryTextFrame: layout.secondaryTextFrame,
                visibleContentRect: layout.visibleContentRect
            )
            self.cache[key] = fallbackResult
            return fallbackResult
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        appearance.performAsCurrentDrawingAppearance {
            let textAttributes = self.textAttributes(color: foregroundColor)

            if let iconImage = self.makeTintedSymbolImage(symbolName: symbolName, color: foregroundColor) {
                iconImage.draw(in: layout.iconFrame)
            }

            if case let .tokenUsage(primaryLine, secondaryLine) = content {
                primaryLine.draw(in: layout.primaryTextFrame, withAttributes: textAttributes)
                secondaryLine.draw(in: layout.secondaryTextFrame, withAttributes: textAttributes)
            }
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: layout.size)
        image.addRepresentation(representation)
        let result = RenderResult(
            image: image,
            iconFrame: layout.iconFrame,
            primaryTextFrame: layout.primaryTextFrame,
            secondaryTextFrame: layout.secondaryTextFrame,
            visibleContentRect: layout.visibleContentRect
        )
        self.cache[key] = result
        return result
    }

    private func foregroundColorKey(for color: NSColor) -> ForegroundColorKey {
        let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? .white
        return ForegroundColorKey(
            red: Int((resolvedColor.redComponent * 1_000).rounded()),
            green: Int((resolvedColor.greenComponent * 1_000).rounded()),
            blue: Int((resolvedColor.blueComponent * 1_000).rounded()),
            alpha: Int((resolvedColor.alphaComponent * 1_000).rounded())
        )
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: self.tokenFont(),
            .foregroundColor: color
        ]
    }

    private func measuredTextSize(_ text: String) -> NSSize {
        let measured = NSAttributedString(
            string: text,
            attributes: [.font: self.tokenFont()]
        ).size()
        return NSSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    private func layout(for content: RenderContent) -> (
        size: NSSize,
        iconFrame: NSRect,
        primaryTextFrame: NSRect,
        secondaryTextFrame: NSRect,
        visibleContentRect: NSRect
    ) {
        switch content {
        case let .tokenUsage(primaryLine, secondaryLine):
            return self.tokenUsageLayout(
                primarySize: self.measuredTextSize(primaryLine),
                secondarySize: self.measuredTextSize(secondaryLine)
            )
        case let .iconOnly(sideLengthBucket):
            return self.iconOnlyLayout(sideLength: CGFloat(sideLengthBucket) / 100)
        }
    }

    private func tokenUsageLayout(
        primarySize: NSSize,
        secondarySize: NSSize
    ) -> (
        size: NSSize,
        iconFrame: NSRect,
        primaryTextFrame: NSRect,
        secondaryTextFrame: NSRect,
        visibleContentRect: NSRect
    ) {
        let textWidth = ceil(max(primarySize.width, secondarySize.width))
        let primaryHeight = ceil(primarySize.height)
        let secondaryHeight = ceil(secondarySize.height)
        let textHeight = primaryHeight + Metrics.lineSpacing + secondaryHeight
        let size = NSSize(
            width: ceil((Metrics.horizontalPadding * 2) + Metrics.iconSize.width + Metrics.iconToTextSpacing + textWidth),
            height: ceil(max(Metrics.iconSize.height, textHeight) + (Metrics.verticalPadding * 2))
        )

        let iconFrame = NSRect(
            x: Metrics.horizontalPadding,
            y: floor((size.height - Metrics.iconSize.height) / 2),
            width: Metrics.iconSize.width,
            height: Metrics.iconSize.height
        )
        let textOriginY = floor((size.height - textHeight) / 2)
        let secondaryTextFrame = NSRect(
            x: iconFrame.maxX + Metrics.iconToTextSpacing,
            y: textOriginY,
            width: textWidth,
            height: secondaryHeight
        )
        let primaryTextFrame = NSRect(
            x: secondaryTextFrame.minX,
            y: secondaryTextFrame.maxY + Metrics.lineSpacing,
            width: textWidth,
            height: primaryHeight
        )
        let visibleContentRect = self.visibleRect(
            containing: iconFrame.union(primaryTextFrame).union(secondaryTextFrame),
            in: size
        )

        return (
            size: size,
            iconFrame: iconFrame,
            primaryTextFrame: primaryTextFrame,
            secondaryTextFrame: secondaryTextFrame,
            visibleContentRect: visibleContentRect
        )
    }

    private func iconOnlyLayout(sideLength: CGFloat) -> (
        size: NSSize,
        iconFrame: NSRect,
        primaryTextFrame: NSRect,
        secondaryTextFrame: NSRect,
        visibleContentRect: NSRect
    ) {
        let edgeLength = ceil(max(sideLength, Metrics.iconSize.width))
        let size = NSSize(width: edgeLength, height: edgeLength)
        let iconFrame = NSRect(
            x: floor((size.width - Metrics.iconSize.width) / 2),
            y: floor((size.height - Metrics.iconSize.height) / 2),
            width: Metrics.iconSize.width,
            height: Metrics.iconSize.height
        )
        let visibleContentRect = self.visibleRect(containing: iconFrame, in: size)

        return (
            size: size,
            iconFrame: iconFrame,
            primaryTextFrame: .zero,
            secondaryTextFrame: .zero,
            visibleContentRect: visibleContentRect
        )
    }

    private func visibleRect(containing rect: NSRect, in size: NSSize) -> NSRect {
        var visibleContentRect = rect
        visibleContentRect = visibleContentRect.insetBy(
            dx: -Metrics.anchorOutset.width,
            dy: -Metrics.anchorOutset.height
        )
        visibleContentRect = visibleContentRect.intersection(NSRect(origin: .zero, size: size)).integral
        return visibleContentRect
    }

    private func bitmapRepresentation(size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let safeScale = max(scale, 1)
        let pixelsWide = max(Int(ceil(size.width * safeScale)), 1)
        let pixelsHigh = max(Int(ceil(size.height * safeScale)), 1)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = size
        return representation
    }

    private func tokenFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
    }

    private func makeFallbackImage(
        layout: (
            size: NSSize,
            iconFrame: NSRect,
            primaryTextFrame: NSRect,
            secondaryTextFrame: NSRect,
            visibleContentRect: NSRect
        ),
        content: RenderContent,
        symbolName: String,
        appearance: NSAppearance,
        foregroundColor: NSColor
    ) -> NSImage {
        let image = NSImage(size: layout.size)
        image.lockFocus()
        defer { image.unlockFocus() }

        appearance.performAsCurrentDrawingAppearance {
            let textAttributes = self.textAttributes(color: foregroundColor)

            if let iconImage = self.makeTintedSymbolImage(symbolName: symbolName, color: foregroundColor) {
                iconImage.draw(in: layout.iconFrame)
            }

            if case let .tokenUsage(primaryLine, secondaryLine) = content {
                primaryLine.draw(in: layout.primaryTextFrame, withAttributes: textAttributes)
                secondaryLine.draw(in: layout.secondaryTextFrame, withAttributes: textAttributes)
            }
        }

        return image
    }

    private func makeSymbolImage(symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: Metrics.symbolPointSize,
            weight: Metrics.symbolWeight,
            scale: Metrics.symbolScale
        )
        return image?.withSymbolConfiguration(configuration) ?? image
    }

    private func makeTintedSymbolImage(symbolName: String, color: NSColor) -> NSImage? {
        guard let image = self.makeSymbolImage(symbolName: symbolName) else {
            return nil
        }

        let tintedImage = NSImage(size: image.size)
        tintedImage.lockFocus()
        defer { tintedImage.unlockFocus() }

        let drawRect = NSRect(origin: .zero, size: image.size)
        image.draw(in: drawRect)
        color.set()
        drawRect.fill(using: .sourceAtop)
        tintedImage.isTemplate = false
        return tintedImage
    }
}
#endif
