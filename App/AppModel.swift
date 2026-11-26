import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum HelperStatus: Equatable { case connecting, missing, outdated(Int), connected }

    // Helper
    @Published private(set) var helperStatus: HelperStatus = .connecting
    @Published private(set) var state: HelperState?
    @Published private(set) var rejection: String?
    @Published private(set) var installing = false
    @Published var installError: String?

    // Profiles
    @Published private(set) var customProfiles: [Profile] = []
    @Published private(set) var selectedID: String
    @Published var draft: [CurvePoint] { didSet { if draft != oldValue { needsPush = true; kick() } } }
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); needsPush = true; kick() }
    }

    /// Show the average temperature next to the fan icon in the menu bar.
    @Published var showMenuTemp: Bool { didSet { defaults.set(showMenuTemp, forKey: Keys.showTemp) } }

    private enum Keys { static let selected = "selectedProfile", enabled = "controlEnabled", showTemp = "showMenuTemp" }
    private let defaults: UserDefaults
    private let store: ProfileStore
    private let client: HelperClient
    private let queue = DispatchQueue(label: "fancurve.helper")
    private var needsPush = true
    private var busy = false
    private var timer: Timer?

    init(socketPath: String? = nil, store: ProfileStore = .standard, defaults: UserDefaults = .standard, autostart: Bool = true) {
        let env = ProcessInfo.processInfo.environment
        self.client = HelperClient(path: socketPath ?? env["FANCURVE_SOCKET"] ?? HelperInstaller.socketPath)
        self.store = store
        self.defaults = defaults
        let custom = store.load()
        let all = Profile.presets + custom
        let saved = defaults.string(forKey: Keys.selected)
        let selected = all.first { $0.id == saved } ?? Profile.presets[1]
        self.customProfiles = custom
        self.selectedID = selected.id
        self.draft = selected.points
        // bool(forKey:) also understands "YES"/"NO" passed as launch arguments; missing key → true.
        self.enabled = defaults.object(forKey: Keys.enabled) == nil || defaults.bool(forKey: Keys.enabled)
        self.showMenuTemp = defaults.object(forKey: Keys.showTemp) == nil || defaults.bool(forKey: Keys.showTemp)
        if autostart { start() }
    }

    // MARK: - Derived

    var allProfiles: [Profile] { Profile.presets + customProfiles }
    var selected: Profile { allProfiles.first { $0.id == selectedID } ?? Profile.presets[1] }
    var isDirty: Bool { draft != selected.points }
    var avgTemp: Double? { state?.cpu.avg }
    /// Mean of all fans, rounded to tens (2541 → 2540), passed through `rpmFilter`:
    /// it changes at most every 3 s and only by ≥ 3 %.
    @Published private(set) var avgRPM: Int?
    private var rpmFilter = DisplayFilter(interval: 3, threshold: 0.03)

    private func updateRPM() {
        let v = state?.fans.compactMap(\.actual) ?? []
        let raw = v.isEmpty ? nil : Int((v.reduce(0, +) / Double(v.count) / 10).rounded()) * 10
        let shown = rpmFilter.update(raw)
        if shown != avgRPM { avgRPM = shown }
    }
    var isOutdated: Bool { if case .outdated = helperStatus { return true }; return false }

    var menuTitle: String {
        guard helperStatus != .missing, let t = avgTemp else { return helperStatus == .missing ? "!" : "—" }
        return "\(Int(t.rounded()))°"
    }

    /// Fan control is not usable yet: no helper, or an old one that has to be replaced.
    var needsAllow: Bool { helperStatus == .missing || isOutdated }

    // MARK: - Helper loop

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func kick() {
        // Apply edits quickly instead of waiting for the next 1 s tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.tick() }
    }

    func tick() {
        guard !busy else { return }
        busy = true
        let current = (enabled, draft)
        let wantPush = needsPush
        needsPush = false
        let client = self.client
        queue.async { [weak self] in
            var status = HelperStatus.connected
            var newState: HelperState?
            var rejection: String?
            var pushFailed = false
            var connectedNow = false
            if !client.isConnected {
                if client.connect(), let v = client.helloVersion() {
                    connectedNow = true
                    client.version = v
                } else {
                    client.disconnect()
                    status = .missing
                }
            }
            // Checked on every tick, not only on connect, so "outdated" doesn't flip back to "connected".
            if client.isConnected, let v = client.version, v < HelperClient.expectedVersion { status = .outdated(v) }
            // A fresh connection has no curve on the helper side yet, so always send it.
            let push = client.isConnected && (wantPush || connectedNow)
            if client.isConnected {
                if push {
                    switch client.control(enabled: current.0, points: current.1) {
                    case .success(let s): newState = s
                    case .failure(let e): rejection = e.message; pushFailed = !client.isConnected
                    }
                }
                if newState == nil { newState = client.state() }
                if newState == nil { status = .missing }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                if pushFailed || (wantPush && !push) { self.needsPush = true }  // retry once reconnected
                if push { self.rejection = rejection }
                if self.needsPush && status == .connected { self.kick() }  // edits made while this tick ran
                if self.helperStatus != status { self.helperStatus = status }
                self.state = newState
                self.updateRPM()
            }
        }
    }

    func installHelper() {
        guard !installing else { return }
        installing = true
        installError = nil
        Task {
            let err = await HelperInstaller.install()
            installing = false
            installError = err?.message
            let client = self.client
            queue.async { client.disconnect() }  // the client is only used on its queue
            helperStatus = .connecting
            needsPush = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            tick()
        }
    }

    // MARK: - Profiles

    func select(_ id: String) {
        guard let p = allProfiles.first(where: { $0.id == id }) else { return }
        selectedID = id
        defaults.set(id, forKey: Keys.selected)
        draft = p.points
    }

    func revertDraft() { draft = selected.points }

    /// Overwrites the selected custom profile with the draft.
    func saveDraft() {
        guard let i = customProfiles.firstIndex(where: { $0.id == selectedID }) else { return }
        customProfiles[i].points = draft
        persist()
    }

    @discardableResult
    func saveDraftAsNew(name: String) -> Profile {
        let p = Profile.custom(name: cleanName(name), points: draft)
        customProfiles.append(p)
        persist()
        select(p.id)
        return p
    }

    func rename(_ id: String, to name: String) {
        guard let i = customProfiles.firstIndex(where: { $0.id == id }) else { return }
        customProfiles[i].name = cleanName(name)
        persist()
    }

    func delete(_ id: String) {
        customProfiles.removeAll { $0.id == id }
        persist()
        if selectedID == id { select(Profile.presets[1].id) }
    }

    /// "My profile 1", "My profile 2", … — the first name not taken yet.
    func suggestedName() -> String {
        let names = Set(allProfiles.map(\.name))
        var n = 1
        while names.contains(L("profile.numbered", n)) { n += 1 }
        return L("profile.numbered", n)
    }

    private func cleanName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? suggestedName() : String(t.prefix(40))
    }

    private func persist() {
        do { try store.save(customProfiles) } catch { installError = L("error.saveProfiles", error.localizedDescription) }
    }

    // MARK: - Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                installError = L("error.launchAtLogin", error.localizedDescription)
            }
        }
    }
}
