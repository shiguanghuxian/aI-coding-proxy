import CodexProxyCore
import Foundation

public final class PtyProcess: @unchecked Sendable {
    public struct Result: Sendable {
        public var output: String
        public var exitCode: Int32
    }

    public init() {}

    public func run(
        launchPath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        password: String? = nil
    ) async throws -> Result {
        let pty = try POSIXCompat.openPseudoTerminal()
        let master = pty.master
        let slave = pty.slave
        defer {
            POSIXCompat.closeDescriptor(master)
            POSIXCompat.closeDescriptor(slave)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        try process.run()

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
        var buffer = Data()
        var sentPasswordCount = 0

        while process.isRunning {
            let chunk = try masterHandle.read(upToCount: 4_096) ?? Data()
            if !chunk.isEmpty {
                buffer.append(chunk)
                if sentPasswordCount < 3,
                   let password,
                   String(decoding: buffer, as: UTF8.self).lowercased().contains("password:")
                {
                    try masterHandle.write(contentsOf: Data((password + "\n").utf8))
                    sentPasswordCount += 1
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        while let chunk = try masterHandle.read(upToCount: 4_096), !chunk.isEmpty {
            buffer.append(chunk)
        }

        process.waitUntilExit()
        return Result(output: String(decoding: buffer, as: UTF8.self), exitCode: process.terminationStatus)
    }
}
