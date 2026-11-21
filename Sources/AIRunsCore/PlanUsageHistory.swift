import CryptoKit
import Foundation

struct PlanUsageSample: Codable, Equatable {
    let capturedAt: Date
    let usedPercent: Double
}

struct PlanUsageCycle: Codable, Equatable {
    let identity: String
    let windowID: String
    let resetsAt: Date
    let durationMinutes: Int?
    let samples: [PlanUsageSample]

    func withSamples(_ samples: [PlanUsageSample]) -> Self {
        Self(identity: identity, windowID: windowID, resetsAt: resetsAt,
             durationMinutes: durationMinutes, samples: samples)
    }
}

struct PlanUsageHistory: Codable, Equatable {
    private static let bucketSeconds: TimeInterval = 300
    private static let retention: TimeInterval = 45 * 86_400
    private static let maximumCycles = 256
    private static let maximumSamples = 8_192

    let cycles: [PlanUsageCycle]

    static func identity(of account: ManagedAccount) -> String? {
        guard account.provider == .codex, let email = account.email?.lowercased(), !email.isEmpty else { return nil }
        // Keep the profile's history separate after a reconnect to another account.
        return Data(SHA256.hash(data: Data(email.utf8))).base64EncodedString()
    }

    static func observations(identity: String, windows: [AccountRateWindow], at date: Date) -> [PlanUsageCycle] {
        guard date.timeIntervalSince1970.isFinite else { return [] }
        return windows.compactMap { window in
            guard let reset = window.resetsAt, reset > date else { return nil }
            return PlanUsageCycle(identity: identity, windowID: window.id, resetsAt: reset,
                                  durationMinutes: window.durationMinutes,
                                  samples: [.init(capturedAt: date, usedPercent: window.usedPercent)])
        }
    }

    func recording(_ observations: [PlanUsageCycle], at date: Date) -> Self {
        let cutoff = date.addingTimeInterval(-Self.retention)
        let entries = observations.reduce(cycles) { cycles, observation in
            guard let index = cycles.firstIndex(where: { $0.sameCycle(as: observation) }) else {
                return cycles + [observation]
            }
            guard let sample = observation.samples.first else { return cycles }
            let cycle = cycles[index]
            let samples = Self.merge(cycle.samples, with: sample)
            return cycles.enumerated().map { $0.offset == index ? cycle.withSamples(samples) : $0.element }
        }
        let recent = entries.compactMap { cycle -> PlanUsageCycle? in
            let samples = cycle.samples.filter { $0.capturedAt >= cutoff }
            return samples.isEmpty ? nil : cycle.withSamples(samples)
        }.sorted {
            ($0.samples.last?.capturedAt ?? .distantPast) > ($1.samples.last?.capturedAt ?? .distantPast)
        }
        let retained = Array(recent.prefix(Self.maximumCycles))
        let dates = retained.flatMap(\.samples).map(\.capturedAt)
        guard dates.count > Self.maximumSamples else { return Self(cycles: retained) }
        let sampleCutoff = dates.sorted(by: >)[Self.maximumSamples]
        let bounded = retained.compactMap { cycle -> PlanUsageCycle? in
            let samples = cycle.samples.filter { $0.capturedAt > sampleCutoff }
            return samples.isEmpty ? nil : cycle.withSamples(samples)
        }
        return Self(cycles: bounded)
    }

    private static func merge(_ samples: [PlanUsageSample], with sample: PlanUsageSample) -> [PlanUsageSample] {
        let bucket = floor(sample.capturedAt.timeIntervalSince1970 / bucketSeconds)
        let match = samples.first { floor($0.capturedAt.timeIntervalSince1970 / bucketSeconds) == bucket }
        if let match, match.capturedAt >= sample.capturedAt { return samples }
        return (samples.filter { $0 != match } + [sample]).sorted { $0.capturedAt < $1.capturedAt }
    }
}

private extension PlanUsageCycle {
    func sameCycle(as other: Self) -> Bool {
        identity == other.identity && windowID == other.windowID && resetsAt == other.resetsAt
            && durationMinutes == other.durationMinutes
    }
}
