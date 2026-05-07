#if os(macOS)
import Foundation
import IOKit.pwr_mgt

protocol DesktopKeepAwakeControlling: AnyObject {
    var isEnabled: Bool { get }

    func setEnabled(_ isEnabled: Bool) throws
}

enum DesktopKeepAwakeError: LocalizedError, Equatable {
    case assertionCreationFailed(kind: String, code: IOReturn)

    var errorDescription: String? {
        switch self {
        case .assertionCreationFailed(let kind, let code):
            return "Failed to create \(kind) power assertion (\(code))."
        }
    }
}

final class DesktopKeepAwakeController: DesktopKeepAwakeControlling {
    private enum AssertionKind: CaseIterable {
        case displaySleep
        case idleSleep

        var type: CFString {
            switch self {
            case .displaySleep:
                return kIOPMAssertionTypeNoDisplaySleep as NSString as CFString
            case .idleSleep:
                return kIOPMAssertionTypeNoIdleSleep as NSString as CFString
            }
        }

        var label: String {
            switch self {
            case .displaySleep:
                return "display sleep"
            case .idleSleep:
                return "idle sleep"
            }
        }
    }

    private struct ActiveAssertion {
        var id: IOPMAssertionID
    }

    private var activeAssertions: [ActiveAssertion] = []

    var isEnabled: Bool {
        self.activeAssertions.isEmpty == false
    }

    deinit {
        self.releaseActiveAssertions()
    }

    func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try self.enable()
        } else {
            self.releaseActiveAssertions()
        }
    }

    private func enable() throws {
        guard self.activeAssertions.isEmpty else { return }

        var createdAssertions: [ActiveAssertion] = []
        do {
            for kind in AssertionKind.allCases {
                var assertionID = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithName(
                    kind.type,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    Self.makeReason(),
                    &assertionID
                )

                guard result == kIOReturnSuccess else {
                    throw DesktopKeepAwakeError.assertionCreationFailed(kind: kind.label, code: result)
                }

                createdAssertions.append(ActiveAssertion(id: assertionID))
            }

            self.activeAssertions = createdAssertions
        } catch {
            Self.release(createdAssertions)
            throw error
        }
    }

    private func releaseActiveAssertions() {
        Self.release(self.activeAssertions)
        self.activeAssertions = []
    }

    private static func release(_ assertions: [ActiveAssertion]) {
        for assertion in assertions {
            IOPMAssertionRelease(assertion.id)
        }
    }

    private static func makeReason() -> CFString {
        "AI Coding Proxy development keep awake" as NSString as CFString
    }
}
#endif
