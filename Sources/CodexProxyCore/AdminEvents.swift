import Foundation

public enum AdminEventType: String, Codable, Sendable, Equatable {
    case requestLogged
    case statsChanged
}

public struct AdminEvent: Codable, Sendable, Equatable {
    public var id: String
    public var sequence: Int64
    public var type: AdminEventType
    public var createdAt: Int64
    public var requestLogID: Int64?

    public init(
        id: String,
        sequence: Int64,
        type: AdminEventType,
        createdAt: Int64,
        requestLogID: Int64? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.type = type
        self.createdAt = createdAt
        self.requestLogID = requestLogID
    }
}

public actor AdminEventHub {
    private var nextSequence: Int64 = 0
    private var subscribers: [UUID: AsyncStream<AdminEvent>.Continuation] = [:]

    public init() {}

    public func subscribe(
        bufferingPolicy: AsyncStream<AdminEvent>.Continuation.BufferingPolicy = .bufferingNewest(100)
    ) -> AsyncStream<AdminEvent> {
        let id = UUID()
        var capturedContinuation: AsyncStream<AdminEvent>.Continuation?
        let stream = AsyncStream<AdminEvent>(bufferingPolicy: bufferingPolicy) { continuation in
            capturedContinuation = continuation
        }

        if let continuation = capturedContinuation {
            self.subscribers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.unsubscribe(id: id)
                }
            }
        }

        return stream
    }

    public func publishRequestLogged(requestLogID: Int64?) {
        self.publish(type: .requestLogged, requestLogID: requestLogID)
    }

    public func publish(type: AdminEventType, requestLogID: Int64? = nil) {
        self.nextSequence += 1
        let sequence = self.nextSequence
        let event = AdminEvent(
            id: String(sequence),
            sequence: sequence,
            type: type,
            createdAt: Helpers.nowMilliseconds(),
            requestLogID: requestLogID
        )

        for continuation in self.subscribers.values {
            continuation.yield(event)
        }
    }

    private func unsubscribe(id: UUID) {
        self.subscribers[id] = nil
    }
}
