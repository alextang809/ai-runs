import Darwin
import Foundation

enum ManagedProcessEvent: Sendable {
    case output(Data), exited(Int32), failed(ManagedAccountClientError)
}

/// Tracks exact child Process objects, never arbitrary provider processes or PIDs.
final class OwnedAccountProcesses: @unchecked Sendable {
    static let shared = OwnedAccountProcesses()
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]

    func insert(_ process: Process, id: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes[id] = process
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        processes[id] = nil
    }

    func terminateAll() {
        lock.lock()
        let owned = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in owned where process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        while owned.contains(where: \.isRunning), ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        for process in owned where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

actor ManagedAccountProcess {
    nonisolated let events: AsyncStream<ManagedProcessEvent>
    private let continuation: AsyncStream<ManagedProcessEvent>.Continuation
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let id = UUID()
    private var outputEnded = false
    private var exitStatus: Int32?
    private var finished = false
    private var outputBytes = 0, errorBytes = 0

    init() {
        let stream = AsyncStream.makeStream(of: ManagedProcessEvent.self, bufferingPolicy: .bufferingOldest(64))
        events = stream.stream
        continuation = stream.continuation
    }

    func start(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw ManagedAccountClientError.launchFailed
        }
        process.terminationHandler = { [weak self] child in
            Task { await self?.didExit(child.terminationStatus) }
        }
        do { try process.run() } catch { throw ManagedAccountClientError.launchFailed }
        OwnedAccountProcesses.shared.insert(process, id: id)
        Self.pump(output.fileHandleForReading) { [weak self] data in
            if let data { await self?.received(data) }
            else { await self?.endedOutput() }
        }
        Self.pump(errors.fileHandleForReading) { [weak self] data in
            if let data { await self?.receivedErrors(data.count) }
        }
    }

    func send(_ data: Data) throws {
        guard !finished, process.isRunning, data.count <= 65_536 else { throw ManagedAccountClientError.cancelled }
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw ManagedAccountClientError.requestFailed }
    }

    func stop(_ reason: ManagedAccountClientError = .cancelled) {
        guard !finished else { return }
        finished = true
        continuation.yield(.failed(reason))
        continuation.finish()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Retain the owner until its bounded SIGKILL fallback has completed.
        Task { [self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            forceStop()
        }
    }

    private func received(_ data: Data) {
        guard !finished else { return }
        outputBytes += data.count
        guard outputBytes <= 4_194_304 else { stop(.outputLimit); return }
        if case .dropped = continuation.yield(.output(data)) { stop(.outputLimit) }
    }

    private func receivedErrors(_ count: Int) {
        errorBytes += count
        if errorBytes > 262_144 { stop(.outputLimit) }
    }

    private func endedOutput() {
        outputEnded = true
        finishIfExited()
    }

    private func didExit(_ status: Int32) {
        exitStatus = status
        OwnedAccountProcesses.shared.remove(id)
        finishIfExited()
    }

    private func finishIfExited() {
        guard outputEnded, let exitStatus, !finished else { return }
        finished = true
        continuation.yield(.exited(exitStatus))
        continuation.finish()
        try? input.fileHandleForWriting.close()
    }

    private func forceStop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        OwnedAccountProcesses.shared.remove(id)
    }

    /// Blocking pipe reads must not occupy Swift's cooperative executor. Acknowledge
    /// each chunk before reading again to preserve ordering and bounded buffering.
    private nonisolated static func pump(_ handle: FileHandle,
        receive: @escaping @Sendable (Data?) async -> Void) {
        DispatchQueue(label: "io.github.alextang809.airuns.account-pipe.\(UUID().uuidString)", qos: .utility).async {
            let acknowledged = DispatchSemaphore(value: 0)
            while let data = readChunk(handle.fileDescriptor) {
                Task {
                    await receive(data)
                    acknowledged.signal()
                }
                acknowledged.wait()
            }
            Task { await receive(nil) }
        }
    }

    private nonisolated static func readChunk(_ descriptor: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, 16_384) }
            if count > 0 { return Data(buffer.prefix(count)) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }
}

actor ManagedAccountRPC {
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private struct Notice: Sendable { let method: String; let parameters: Data }
    private struct Waiting {
        let method: String
        let matching: [String: String]
        let pending: Pending
    }
    private let child: ManagedAccountProcess
    private var pending: [String: Pending] = [:]
    private var waiting: [UUID: Waiting] = [:]
    private var notices: [Notice] = []
    private var buffer = Data()
    private var reader: Task<Void, Never>?
    private var closed = false

    init(child: ManagedAccountProcess) { self.child = child }

    func isOpen() -> Bool { !closed }

    func beginReading() {
        reader = Task { [weak self, child] in
            for await event in child.events {
                guard let self else { return }
                await self.receive(event)
            }
        }
    }

    func request(_ method: String, parameters: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        guard !closed, pending.count < 8 else { throw ManagedAccountClientError.requestFailed }
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(timeout)) } catch { return }
                    await self?.requestExpired(id)
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                Task { await self.writeRequest(id: id, method: method, parameters: parameters) }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    func notify(_ method: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["method": method]) + Data([0x0A])
        try await child.send(data)
    }

    func waitFor(_ method: String, matching: [String: String], timeout: TimeInterval) async throws -> Data {
        if let index = notices.firstIndex(where: { $0.method == method && Self.matches($0.parameters, matching) }) {
            return notices.remove(at: index).parameters
        }
        guard !closed else { throw ManagedAccountClientError.cancelled }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: Self.nanoseconds(timeout)) } catch { return }
                    await self?.noticeExpired(id)
                }
                waiting[id] = Waiting(method: method, matching: matching,
                    pending: Pending(continuation: continuation, timeout: timer))
            }
        } onCancel: {
            Task { await self.cancelNotice(id) }
        }
    }

    func stop() async {
        failAll(.cancelled)
        await child.stop()
        reader?.cancel()
    }

    private func writeRequest(id: String, method: String, parameters: Data?) async {
        do {
            var object: [String: Any] = ["id": id, "method": method]
            if let parameters { object["params"] = try JSONSerialization.jsonObject(with: parameters) }
            let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
            try await child.send(data)
        } catch {
            complete(id, result: .failure(ManagedAccountClientError.requestFailed))
        }
    }

    private func receive(_ event: ManagedProcessEvent) {
        switch event {
        case .output(let data):
            buffer.append(data)
            guard buffer.count <= 262_144 else { failAndStop(.outputLimit); return }
            while let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: index)
                buffer.removeSubrange(...index)
                if !line.isEmpty { receiveLine(Data(line)) }
            }
        case .exited: failAll(.requestFailed)
        case .failed(let error): failAll(error)
        }
    }

    private func receiveLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            failAndStop(.invalidResponse)
            return
        }
        if let id = object["id"] as? String {
            if object["error"] != nil { complete(id, result: .failure(ManagedAccountClientError.requestFailed)) }
            else if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                complete(id, result: .success(data))
            } else { complete(id, result: .failure(ManagedAccountClientError.invalidResponse)) }
            return
        }
        guard object["method"] as? String == "account/login/completed",
              let parameters = object["params"],
              let data = try? JSONSerialization.data(withJSONObject: parameters) else { return }
        if let match = waiting.first(where: { $0.value.method == "account/login/completed" && Self.matches(data, $0.value.matching) }) {
            waiting[match.key] = nil
            match.value.pending.timeout.cancel()
            match.value.pending.continuation.resume(returning: data)
        } else if notices.count < 16 {
            notices.append(Notice(method: "account/login/completed", parameters: data))
        }
    }

    private func complete(_ id: String, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func requestExpired(_ id: String) {
        complete(id, result: .failure(ManagedAccountClientError.timedOut))
    }

    private func cancelRequest(_ id: String) {
        complete(id, result: .failure(ManagedAccountClientError.cancelled))
    }

    private func noticeExpired(_ id: UUID) {
        guard let notice = waiting.removeValue(forKey: id) else { return }
        notice.pending.continuation.resume(throwing: ManagedAccountClientError.timedOut)
    }

    private func cancelNotice(_ id: UUID) {
        guard let notice = waiting.removeValue(forKey: id) else { return }
        notice.pending.timeout.cancel()
        notice.pending.continuation.resume(throwing: ManagedAccountClientError.cancelled)
    }

    private func failAndStop(_ error: ManagedAccountClientError) {
        failAll(error)
        Task { await child.stop(error) }
    }

    private func failAll(_ error: ManagedAccountClientError) {
        guard !closed else { return }
        closed = true
        for request in pending.values { request.timeout.cancel(); request.continuation.resume(throwing: error) }
        for notice in waiting.values { notice.pending.timeout.cancel(); notice.pending.continuation.resume(throwing: error) }
        pending.removeAll()
        waiting.removeAll()
        notices.removeAll()
    }

    private static func matches(_ data: Data, _ expected: [String: String]) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return expected.allSatisfy { object[$0.key] as? String == $0.value }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0.01, min(seconds.isFinite ? seconds : 30, 600)) * 1_000_000_000)
    }
}
