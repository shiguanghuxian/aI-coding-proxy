import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum POSIXCompat {
    public struct PseudoTerminal: Sendable {
        public var master: Int32
        public var slave: Int32

        public init(master: Int32, slave: Int32) {
            self.master = master
            self.slave = slave
        }
    }

    public static func openPseudoTerminal() throws -> PseudoTerminal {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw ProxyError.message("openpty failed")
        }
        return PseudoTerminal(master: master, slave: slave)
    }

    public static func closeDescriptor(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = close(fd)
    }

    public static func shutdownReadWrite(_ fd: Int32) {
        #if canImport(Darwin)
        _ = shutdown(fd, SHUT_RDWR)
        #else
        _ = shutdown(fd, Int32(SHUT_RDWR))
        #endif
    }

    public static func makeTCPIPv4StreamSocket() -> Int32 {
        socket(AF_INET, Self.streamSocketType, 0)
    }

    public static func accept(_ fd: Int32) -> Int32 {
        Self.platformAccept(fd)
    }

    public static func receive(
        _ fd: Int32,
        buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        recv(fd, buffer, count, 0)
    }

    public static func setReuseAddress(_ fd: Int32) -> Bool {
        var reuse: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    public static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    public static func configureClientSocket(_ fd: Int32) {
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    public static func bindLoopback(_ fd: Int32, port: Int) -> Bool {
        var address = Self.loopbackAddress(port: port)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Self.platformBind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        } == 0
    }

    public static func listen(_ fd: Int32, backlog: Int32) -> Bool {
        Self.platformListen(fd, backlog) == 0
    }

    public static func canConnectTCPIPv4Loopback(port: Int) -> Bool {
        guard port > 0 && port <= 65_535 else { return false }

        let socketFD = Self.makeTCPIPv4StreamSocket()
        guard socketFD >= 0 else { return false }
        defer { Self.closeDescriptor(socketFD) }

        Self.configureClientSocket(socketFD)
        var address = Self.loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Self.platformConnect(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        return result == 0
    }

    public static func localPort(for fd: Int32) -> Int? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    public static func sendAll(_ fd: Int32, data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return true
            }

            while offset < data.count {
                let remaining = data.count - offset
                let written = Self.platformSend(fd, baseAddress.advanced(by: offset), remaining)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    return false
                }
                if Self.lastErrno() == Self.interruptedErrorCode {
                    continue
                }
                return false
            }
            return true
        }
    }

    public static func canBindTCPIPv4Loopback(port: Int) -> Bool {
        guard port > 0 && port <= 65_535 else { return false }

        let socketFD = Self.makeTCPIPv4StreamSocket()
        guard socketFD >= 0 else { return false }
        defer { Self.closeDescriptor(socketFD) }

        _ = Self.setReuseAddress(socketFD)
        return Self.bindLoopback(socketFD, port: port)
    }

    public static func availableTCPIPv4LoopbackPort(preferred: Int) -> Int? {
        if preferred > 0, Self.canBindTCPIPv4Loopback(port: preferred) {
            return preferred
        }

        let socketFD = Self.makeTCPIPv4StreamSocket()
        guard socketFD >= 0 else { return nil }
        defer { Self.closeDescriptor(socketFD) }

        guard Self.bindLoopback(socketFD, port: 0) else { return nil }
        return Self.localPort(for: socketFD)
    }

    public static func terminateProcess(_ pid: Int32) {
        guard pid > 0 else { return }
        _ = kill(pid, SIGTERM)
        for _ in 0..<10 {
            if kill(pid, 0) != 0 {
                return
            }
            usleep(200_000)
        }
        _ = kill(pid, SIGKILL)
    }

    public static var wouldBlockErrorCode: Int32 { EWOULDBLOCK }
    public static var againErrorCode: Int32 { EAGAIN }
    public static var badFileDescriptorErrorCode: Int32 { EBADF }
    public static var invalidArgumentErrorCode: Int32 { EINVAL }
    public static var interruptedErrorCode: Int32 { EINTR }

    public static func lastErrno() -> Int32 {
        errno
    }

    public static func lastErrorMessage(code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    #if canImport(Darwin)
    private static let streamSocketType = SOCK_STREAM

    private static func platformAccept(_ fd: Int32) -> Int32 {
        Darwin.accept(fd, nil, nil)
    }

    private static func platformBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.bind(fd, address, length)
    }

    private static func platformListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        Darwin.listen(fd, backlog)
    }

    private static func platformConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.connect(fd, address, length)
    }

    private static func platformSend(_ fd: Int32, _ buffer: UnsafePointer<UInt8>, _ count: Int) -> Int {
        Darwin.send(fd, buffer, count, 0)
    }
    #else
    #if canImport(Glibc)
    private static let streamSocketType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamSocketType = SOCK_STREAM
    #endif

    private static func platformAccept(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.accept(fd, nil, nil)
        #else
        Musl.accept(fd, nil, nil)
        #endif
    }

    private static func platformBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.bind(fd, address, length)
        #else
        Musl.bind(fd, address, length)
        #endif
    }

    private static func platformListen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.listen(fd, backlog)
        #else
        Musl.listen(fd, backlog)
        #endif
    }

    private static func platformConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.connect(fd, address, length)
        #else
        Musl.connect(fd, address, length)
        #endif
    }

    private static func platformSend(_ fd: Int32, _ buffer: UnsafePointer<UInt8>, _ count: Int) -> Int {
        #if canImport(Glibc)
        Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        #else
        Musl.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        #endif
    }
    #endif
}
