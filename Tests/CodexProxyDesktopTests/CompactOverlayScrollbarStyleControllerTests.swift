#if os(macOS)
import AppKit
import XCTest
@testable import CodexProxyDesktop

@MainActor
final class CompactOverlayScrollbarStyleControllerTests: XCTestCase {
    func testApplyAroundConfiguresNestedScrollViewsAsCompactOverlay() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let probeContainer = NSView(frame: rootView.bounds)
        let outerScrollView = self.makeScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let innerScrollView = self.makeScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        let innerHostView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        let probeView = NSView(frame: .zero)

        rootView.addSubview(probeContainer)
        probeContainer.addSubview(outerScrollView)
        probeContainer.addSubview(probeView)

        outerScrollView.documentView = innerHostView
        innerHostView.addSubview(innerScrollView)

        CompactOverlayScrollbarStyleController.apply(around: probeView)

        self.assertCompactOverlay(scrollView: outerScrollView)
        self.assertCompactOverlay(scrollView: innerScrollView)
    }

    private func makeScrollView(frame: NSRect) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.verticalScroller?.scrollerStyle = .legacy
        scrollView.verticalScroller?.controlSize = .regular
        scrollView.horizontalScroller?.scrollerStyle = .legacy
        scrollView.horizontalScroller?.controlSize = .regular
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        return scrollView
    }

    private func assertCompactOverlay(scrollView: NSScrollView) {
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.verticalScroller?.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .small)
        XCTAssertEqual(scrollView.horizontalScroller?.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.horizontalScroller?.controlSize, .small)
    }
}
#endif
