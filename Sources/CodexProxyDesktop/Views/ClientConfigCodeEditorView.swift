#if os(macOS)
import AppKit
import SwiftUI

struct ClientConfigCodeEditorView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let textIdentity: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.string = self.text
        scrollView.documentView = textView
        context.coordinator.appliedTextIdentity = self.textIdentity
        context.coordinator.appliedColorScheme = self.colorScheme
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.appliedTextIdentity != self.textIdentity {
            let selectedRange = textView.selectedRange()
            textView.string = self.text
            if selectedRange.location + selectedRange.length <= (self.text as NSString).length {
                textView.setSelectedRange(selectedRange)
            }
            context.coordinator.appliedTextIdentity = self.textIdentity
        }
        if context.coordinator.appliedColorScheme != self.colorScheme {
            textView.textColor = NSColor.labelColor
            textView.backgroundColor = .clear
            scrollView.drawsBackground = false
            context.coordinator.appliedColorScheme = self.colorScheme
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var appliedTextIdentity: String?
        var appliedColorScheme: ColorScheme?
    }
}
#endif
