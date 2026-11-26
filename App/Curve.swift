import Foundation

/// One point of a fan curve: average core temperature (°C) → fan level (% of min…max RPM).
struct CurvePoint: Codable, Hashable {
    var temp: Double
    var pct: Double
}

enum Curve {
    static let tempRange: ClosedRange<Double> = 30...100
    static let minGap: Double = 1
    static let maxPoints = 12

    /// Linear interpolation, flat outside the first/last point. Same math as the helper.
    static func value(_ points: [CurvePoint], at t: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.temp { return first.pct }
        for (a, b) in zip(points, points.dropFirst()) where t <= b.temp {
            return a.pct + (b.pct - a.pct) * (t - a.temp) / (b.temp - a.temp)
        }
        return last.pct
    }

    /// Sorted, rounded, clamped, and never slower when hotter.
    static func normalized(_ points: [CurvePoint]) -> [CurvePoint] {
        var out = points
            .map { CurvePoint(temp: min(max($0.temp.rounded(), tempRange.lowerBound), tempRange.upperBound),
                              pct: min(max($0.pct.rounded(), 0), 100)) }
            .sorted { $0.temp < $1.temp }
        var i = 1
        while i < out.count {
            if out[i].temp - out[i - 1].temp < minGap { out.remove(at: i); continue }
            out[i].pct = max(out[i].pct, out[i - 1].pct)
            i += 1
        }
        return out
    }

    static func isValid(_ points: [CurvePoint]) -> Bool {
        points.count >= 2 && points.count <= maxPoints && normalized(points) == points
    }
}

/// Calms a jittery number for display: it changes at most once per `interval`,
/// and only when the new value differs from the shown one by at least `threshold` (relative).
struct DisplayFilter {
    var interval: TimeInterval = 3
    var threshold: Double = 0.03
    private(set) var shown: Int?
    private var changedAt: Date = .distantPast

    init(interval: TimeInterval = 3, threshold: Double = 0.03) {
        self.interval = interval
        self.threshold = threshold
    }

    /// Feeds a new reading; returns the value to show.
    @discardableResult
    mutating func update(_ value: Int?, now: Date = Date()) -> Int? {
        guard let value else { shown = nil; return nil }  // no data → show "—" at once
        guard let current = shown else { shown = value; changedAt = now; return value }  // first value: no wait
        let relative = abs(Double(value - current)) / max(Double(abs(current)), 1)
        if now.timeIntervalSince(changedAt) >= interval && relative >= threshold {
            shown = value
            changedAt = now
        }
        return shown
    }
}

struct Profile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var points: [CurvePoint]
    var builtin: Bool = false

    static func custom(name: String, points: [CurvePoint]) -> Profile {
        Profile(id: "custom-" + UUID().uuidString, name: name, points: points)
    }
}

extension Profile {
    private static func make(_ id: String, _ name: String, _ p: [(Double, Double)]) -> Profile {
        Profile(id: id, name: name, points: p.map { CurvePoint(temp: $0.0, pct: $0.1) }, builtin: true)
    }

    /// Ordered from quietest to coolest.
    static let presets: [Profile] = [
        make("quiet", L("preset.quiet"), [(50, 0), (65, 10), (75, 35), (85, 70), (92, 100)]),
        make("balanced", L("preset.balanced"), [(40, 0), (55, 20), (65, 40), (75, 70), (85, 100)]),
        make("cool", L("preset.cool"), [(40, 5), (52, 30), (62, 50), (72, 80), (80, 100)]),
        make("cold", L("preset.cold"), [(35, 10), (48, 35), (58, 60), (68, 85), (76, 100)]),
        make("very-cold", L("preset.veryCold"), [(30, 30), (45, 55), (55, 80), (62, 100)]),
    ]
}

/// Custom profiles live in ~/Library/Application Support/FanCurve/profiles.json.
struct ProfileStore {
    var url: URL

    static var standard: ProfileStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanCurve", isDirectory: true)
        return ProfileStore(url: dir.appendingPathComponent("profiles.json"))
    }

    func load() -> [Profile] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Profile].self, from: data) else { return [] }
        return list.filter { !$0.builtin && Curve.isValid($0.points) }
    }

    func save(_ profiles: [Profile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(profiles.filter { !$0.builtin }).write(to: url, options: .atomic)
    }
}
