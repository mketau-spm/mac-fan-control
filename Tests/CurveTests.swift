// Plain test runner for Curve/Profile logic (no XCTest needed): swiftc App/Localization.swift App/Curve.swift Tests/CurveTests.swift
import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    print((cond ? "PASS " : "FAIL ") + name + (cond ? "" : "  [\(detail())]"))
    if !cond { failures += 1 }
}
func pts(_ a: [(Double, Double)]) -> [CurvePoint] { a.map { CurvePoint(temp: $0.0, pct: $0.1) } }

@main
enum CurveTests {
    static func main() throws {
        let c = pts([(40, 0), (60, 50), (80, 100)])
        check("below first point → first value", Curve.value(c, at: 20) == 0)
        check("interpolates", Curve.value(c, at: 50) == 25, "\(Curve.value(c, at: 50))")
        check("on a point", Curve.value(c, at: 60) == 50)
        check("above last point → last value", Curve.value(c, at: 99) == 100)
        check("empty curve → 0", Curve.value([], at: 50) == 0)

        let n = Curve.normalized(pts([(60, 20), (40, 50), (40.4, 10), (120, 130)]))
        check("normalize sorts, drops too-close points, clamps, keeps rising",
              n == pts([(40, 50), (60, 50), (100, 100)]), "\(n)")
        check("valid curve", Curve.isValid(c))
        check("one point is invalid", !Curve.isValid(pts([(40, 0)])))
        check("falling curve is invalid", !Curve.isValid(pts([(40, 50), (60, 10)])))

        check("5 presets", Profile.presets.count == 5)
        check("all presets valid", Profile.presets.allSatisfy { Curve.isValid($0.points) })
        check("preset ids unique", Set(Profile.presets.map(\.id)).count == 5)
        let at70 = Profile.presets.map { Curve.value($0.points, at: 70) }
        check("presets go from quietest to coolest at 70 °C", at70 == at70.sorted(), "\(at70)")
        check("every preset reaches 100 % by 92 °C", Profile.presets.allSatisfy { Curve.value($0.points, at: 92) == 100 })

        var f = DisplayFilter(interval: 3, threshold: 0.03)
        let t0 = Date(timeIntervalSince1970: 1000)
        check("filter: first value shows at once", f.update(2500, now: t0) == 2500)
        check("filter: big change within 3 s is held", f.update(4000, now: t0.addingTimeInterval(1)) == 2500)
        check("filter: big change after 3 s shows", f.update(4000, now: t0.addingTimeInterval(3)) == 4000)
        check("filter: < 3 % change after 3 s is ignored", f.update(4100, now: t0.addingTimeInterval(10)) == 4000)
        check("filter: ≥ 3 % change after 3 s shows", f.update(4120, now: t0.addingTimeInterval(10)) == 4120)
        check("filter: drops are filtered the same way", f.update(4050, now: t0.addingTimeInterval(20)) == 4120)
        check("filter: no data clears at once", f.update(nil, now: t0.addingTimeInterval(20.5)) == nil)
        check("filter: value after no data shows at once", f.update(1350, now: t0.addingTimeInterval(21)) == 1350)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileStore(url: dir.appendingPathComponent("profiles.json"))
        check("missing file → no custom profiles", store.load().isEmpty)
        let mine = Profile.custom(name: "Мой", points: c)
        try store.save([mine] + Profile.presets)
        let loaded = store.load()
        check("custom profile round-trips; presets are not stored", loaded == [mine], "\(loaded)")
        try Data("garbage".utf8).write(to: store.url)
        check("corrupt file → empty list, no crash", store.load().isEmpty)
        try? FileManager.default.removeItem(at: dir)

        print("\n\(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
