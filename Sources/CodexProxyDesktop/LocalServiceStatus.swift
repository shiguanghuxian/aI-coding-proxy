#if os(macOS)
import Foundation

struct LocalServiceStatus: Sendable, Equatable {
    var installed: Bool
    var running: Bool
    var launchctlState: String
    var stdoutPath: String
    var stderrPath: String
    var lastErrorSummary: String?
}
#endif
