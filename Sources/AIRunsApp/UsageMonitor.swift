import AIRunsCore
import Combine
import Foundation

protocol UsageWorking: Actor {
    func refresh(period: UsagePeriod, forceDiscovery: Bool) async -> UsageSnapshot
    func currentSnapshot(period: UsagePeriod) async -> UsageSnapshot
    func updateManagedRoots(_ roots: [UsageSourceRoot]) async
}

/// All source I/O, parsing, cache writes and aggregation stay off the main actor.
actor LocalUsageWorker: UsageWorking {
    private let nativeRoots: [UsageSourceRoot]
    private var scanner: UsageScanner
    private var latest: UsageScanOutput?

    init(paths: AIRunsPaths, roots: [UsageSourceRoot] = UsageSourceRoot.defaults()) {
        nativeRoots = roots
        scanner = UsageScanner(roots: roots, cacheURL: paths.root.appendingPathComponent("usage-cache-v1.json"))
    }

    func refresh(period: UsagePeriod, forceDiscovery: Bool) -> UsageSnapshot {
        let now = Date()
        let output = scanner.scan(now: now, forceDiscovery: forceDiscovery)
        latest = output
        return UsageLedger.snapshot(output, period: period, now: now)
    }

    func currentSnapshot(period: UsagePeriod) -> UsageSnapshot {
        guard let latest else { return .loading(period: period) }
        return UsageLedger.snapshot(latest, period: period, now: Date())
    }

    func updateManagedRoots(_ roots: [UsageSourceRoot]) { scanner.updateRoots(nativeRoots + roots) }
}

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var period: UsagePeriod
    private let worker: any UsageWorking
    private let defaults: UserDefaults
    private var scanTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var isRunning = false
    private var forceRequested = false
    private var epoch = UUID()
    static let periodKey = "usage.period"

    init(paths: AIRunsPaths = AIRunsPaths(), defaults: UserDefaults = .standard,
         worker: (any UsageWorking)? = nil) {
        self.defaults = defaults
        self.worker = worker ?? LocalUsageWorker(paths: paths)
        let selected = defaults.string(forKey: Self.periodKey).flatMap(UsagePeriod.init(rawValue:)) ?? .last24Hours
        period = selected
        snapshot = .loading(period: selected)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshNow()
    }

    func stop() {
        isRunning = false
        epoch = UUID()
        scanTask?.cancel(); scanTask = nil
        timerTask?.cancel(); timerTask = nil
        selectionTask?.cancel(); selectionTask = nil
    }

    func refreshNow() {
        forceRequested = true
        timerTask?.cancel(); timerTask = nil
        if isRunning { runPass() }
    }

    func select(_ selected: UsagePeriod) {
        guard selected != period else { return }
        period = selected
        defaults.set(selected.rawValue, forKey: Self.periodKey)
        snapshot = .loading(period: selected)
        selectionTask?.cancel()
        let generation = epoch
        selectionTask = Task { [weak self, worker] in
            let value = await worker.currentSnapshot(period: selected)
            guard let self, !Task.isCancelled, self.epoch == generation, self.period == selected else { return }
            self.snapshot = value
        }
    }

    func includeManagedRoots(_ roots: [UsageSourceRoot]) {
        let generation = epoch
        Task { [weak self, worker] in
            await worker.updateManagedRoots(roots)
            guard let self, self.epoch == generation else { return }
            if self.isRunning { self.refreshNow() } else { self.start() }
        }
    }

    private func runPass() {
        guard isRunning, scanTask == nil else { return }
        let selected = period, generation = epoch, force = forceRequested
        forceRequested = false
        scanTask = Task { [weak self, worker] in
            let value = await worker.refresh(period: selected, forceDiscovery: force)
            guard let self, !Task.isCancelled, self.epoch == generation else { return }
            if self.period == selected { self.snapshot = value }
            self.scanTask = nil
            if self.forceRequested { self.runPass(); return }
            let scanning = value.providers.contains { $0.coverage == .scanning }
            self.schedule(after: scanning ? 200_000_000 : 30_000_000_000)
        }
    }

    private func schedule(after delay: UInt64) {
        timerTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.timerTask = nil
            self.runPass()
        }
    }
}
