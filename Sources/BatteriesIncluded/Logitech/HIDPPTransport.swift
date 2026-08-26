import Foundation

protocol HIDPPDeviceIO: Sendable {
    func write(_ report: [UInt8]) throws
}

actor HIDPPTransport: HIDPPRequesting {
    private struct PendingRequest {
        let id: UInt64
        let packet: HIDPPPacket
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    private let io: any HIDPPDeviceIO
    private let timeout: Duration
    private var nextRequestID: UInt64 = 0
    private var activeRequest: PendingRequest?
    private var queuedRequests: [PendingRequest] = []
    private var responseTombstones: [HIDPPPacket] = []
    private var timeoutTask: Task<Void, Never>?
    private var isRemoved = false

    init(io: any HIDPPDeviceIO, timeout: Duration = .milliseconds(250)) {
        self.io = io
        self.timeout = timeout
    }

    var pendingRequestCount: Int {
        (activeRequest == nil ? 0 : 1) + queuedRequests.count
    }

    func send(_ packet: HIDPPPacket) async throws -> [UInt8] {
        let requestID = nextRequestID
        nextRequestID &+= 1
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !isRemoved else {
                    continuation.resume(throwing: HIDPPError.disconnected)
                    return
                }

                queuedRequests.append(PendingRequest(
                    id: requestID,
                    packet: packet,
                    continuation: continuation
                ))
                startNextRequestIfNeeded()
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID) }
        }
    }

    func receive(_ report: [UInt8]) {
        if let tombstoneIndex = responseTombstones.firstIndex(where: {
            $0.matchesResponse(report) || $0.protocolError(in: report) != nil
        }) {
            responseTombstones.remove(at: tombstoneIndex)
            return
        }

        guard let activeRequest else { return }

        if let error = activeRequest.packet.protocolError(in: report) {
            finishActive(with: .failure(error))
        } else if activeRequest.packet.matchesResponse(report) {
            finishActive(with: .success(report))
        }
    }

    func interfaceRemoved() {
        guard !isRemoved else { return }
        isRemoved = true

        if activeRequest != nil {
            finishActive(with: .failure(HIDPPError.disconnected))
        }

        let disconnectedRequests = queuedRequests
        queuedRequests.removeAll()
        for request in disconnectedRequests {
            request.continuation.resume(throwing: HIDPPError.disconnected)
        }
    }

    private func startNextRequestIfNeeded() {
        guard activeRequest == nil, !isRemoved, !queuedRequests.isEmpty else { return }

        let request = queuedRequests.removeFirst()
        guard !responseTombstones.contains(where: {
            sharesResponseCorrelation($0, request.packet)
        }) else {
            request.continuation.resume(throwing: HIDPPError.disconnected)
            startNextRequestIfNeeded()
            return
        }

        activeRequest = request
        do {
            try io.write(request.packet.bytes)
        } catch {
            finishActive(with: .failure(error))
            return
        }

        timeoutTask = Task { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeout(requestID: request.id)
        }
    }

    private func timeout(requestID: UInt64) {
        guard let activeRequest, activeRequest.id == requestID else { return }
        responseTombstones.append(activeRequest.packet)
        finishActive(with: .failure(HIDPPError.timeout))
    }

    private func cancel(requestID: UInt64) {
        if let activeRequest, activeRequest.id == requestID {
            responseTombstones.append(activeRequest.packet)
            finishActive(with: .failure(CancellationError()))
            return
        }

        guard let queuedIndex = queuedRequests.firstIndex(where: { $0.id == requestID }) else {
            return
        }
        let request = queuedRequests.remove(at: queuedIndex)
        request.continuation.resume(throwing: CancellationError())
    }

    private func sharesResponseCorrelation(_ first: HIDPPPacket, _ second: HIDPPPacket) -> Bool {
        first.bytes[1...3].elementsEqual(second.bytes[1...3])
    }

    private func finishActive(with result: Result<[UInt8], Error>) {
        guard let request = activeRequest else { return }
        activeRequest = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        request.continuation.resume(with: result)
        startNextRequestIfNeeded()
    }
}
