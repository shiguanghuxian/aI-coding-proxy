#if os(macOS)
import AppKit
import CodexProxyCore
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let behavior: WindowCloseBehavior
    let title: String
    let identifier: NSUserInterfaceItemIdentifier?
    let themeMode: DesktopThemeMode

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                if let identifier = self.identifier {
                    window.identifier = identifier
                }
                window.title = self.title
                window.delegate = context.coordinator
                AppearanceStore.applyWindowAppearance(window, for: self.themeMode)
                self.applyToolbarAppearance(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.behavior = self.behavior
        DispatchQueue.main.async {
            if let window = nsView.window {
                if let identifier = self.identifier {
                    window.identifier = identifier
                }
                window.title = self.title
                window.delegate = context.coordinator
                AppearanceStore.applyWindowAppearance(window, for: self.themeMode)
                self.applyToolbarAppearance(window)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(behavior: self.behavior)
    }

    private func applyToolbarAppearance(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.toolbar?.showsBaselineSeparator = false
        window.toolbarStyle = .unifiedCompact
        window.styleMask.insert(.fullSizeContentView)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var behavior: WindowCloseBehavior

        init(behavior: WindowCloseBehavior) {
            self.behavior = behavior
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard self.behavior == .hideToMenuBar else {
                return true
            }
            sender.orderOut(nil)
            NSApp.hide(nil)
            return false
        }
    }
}
#endif
