import SwiftUI

// The whole app is this popover: temperature, fan speed, switch, curve, profile.
// Everything rare lives in the gear menu. All text comes from Localization/<lang>.lproj via L().

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.state?.mode == "failsafe" ? "fan.badge.automatic" : "fan")
            if model.showMenuTemp {
                Text(verbatim: model.menuTitle).monospacedDigit()
            }
        }
    }
}

/// Big bold number whose digits roll up or down when the value changes.
struct RollingNumber: View {
    var value: Int?
    var suffix: String

    var body: some View {
        // verbatim: no locale grouping ("5 340"), which made the number wider than the space for it
        Text(verbatim: value.map { "\($0)\(suffix)" } ?? "—")
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText(value: Double(value ?? 0)))
            .animation(.snappy(duration: 0.45), value: value)
    }
}

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var naming: Naming?
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    enum Naming: Equatable { case saveAs, rename }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            notice
            CurveEditor(points: $model.draft, currentTemp: model.curveTemp, rawTemp: model.avgTemp,
                        failsafeTemp: model.state?.failsafe.avg ?? 95, compact: true)
                .frame(height: 150)
                .opacity(model.needsAllow ? 0.35 : (model.enabled ? 1 : 0.45))
                .disabled(model.needsAllow)  // nothing to apply the curve to without fan control
                .help(L("help.curve"))
            if naming != nil { nameField } else { footer }
        }
        .padding(14)
        .frame(width: 300)
        // Solid fill over the system's translucent popover material: nothing shows through.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: header — temperature, fan speed, switch

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            RollingNumber(value: model.avgTemp.map { Int($0.rounded()) }, suffix: "°")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                RollingNumber(value: model.avgRPM, suffix: "")
                Text(L("unit.rpm")).font(.caption.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            }
            Spacer()
            // No switch until fan control is allowed: a disabled "on" switch only confuses.
            Toggle("", isOn: $model.enabled)
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .opacity(model.needsAllow ? 0 : 1)
                .disabled(model.needsAllow || model.state == nil)
                .help(model.enabled ? L("help.toggleOn") : L("help.toggleOff"))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }

    // MARK: notices — only when something needs attention

    @ViewBuilder private var notice: some View {
        if model.needsAllow {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.installHelper() } label: {
                    Text(model.installing ? L("button.allowing") : L("button.allow"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.installing)
                if let e = model.installError {
                    Text(e).font(.caption2).foregroundStyle(.red).lineLimit(3)
                }
            }
        } else if model.state?.mode == "failsafe" {
            Text(L("notice.failsafe")).font(.caption).foregroundStyle(.red)
        } else if let err = model.state?.error {
            Text(L("error.smc", err))
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if let r = model.rejection ?? model.installError {
            Text(r).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: footer — profile picker, unsaved changes, "…"

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                // Inline pickers give native checkmarks; a divider separates presets from your own.
                Picker("", selection: profileBinding) {
                    ForEach(Profile.presets) { Text(verbatim: $0.name).tag($0.id) }
                }
                .pickerStyle(.inline).labelsHidden()
                if !model.customProfiles.isEmpty {
                    Picker("", selection: profileBinding) {
                        ForEach(model.customProfiles) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            } label: {
                Text(verbatim: model.selected.name + (model.isDirty ? " •" : ""))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if model.isDirty {
                Button { model.revertDraft() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(L("help.revert"))
                Button {
                    if model.selected.builtin { startNaming(.saveAs) } else { model.saveDraft() }
                } label: { Image(systemName: "checkmark") }
                    .help(model.selected.builtin ? L("help.saveAsOwn") : L("help.save"))
                    .foregroundStyle(Color.accentColor)
            }

            Menu {
                // New profiles come from editing the curve and pressing ✓; this menu only manages them.
                if !model.selected.builtin {
                    if model.isDirty { Button(L("menu.saveAsNew")) { startNaming(.saveAs) } }
                    Button(L("menu.rename")) { startNaming(.rename) }
                    Button(L("menu.delete"), role: .destructive) { model.delete(model.selectedID) }
                    Divider()
                }
                Picker(L("menu.response"), selection: $model.response) {
                    ForEach(AppModel.Response.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Toggle(L("menu.showTemp"), isOn: $model.showMenuTemp)
                Toggle(L("menu.launchAtLogin"), isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Divider()
                Button(L("menu.quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var profileBinding: Binding<String> {
        Binding(get: { model.selectedID }, set: { model.select($0) })
    }

    // MARK: inline naming (sheets don't work inside a menu bar popover)

    private func startNaming(_ kind: Naming) {
        name = kind == .rename ? model.selected.name : model.suggestedName()
        naming = kind
        DispatchQueue.main.async { nameFocused = true }
    }

    private var nameField: some View {
        HStack(spacing: 8) {
            TextField(naming == .rename ? L("name.new") : L("name.profile"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onExitCommand { naming = nil }
            Button(L("button.cancel")) { naming = nil }.buttonStyle(.borderless)
            Button(L("button.ok"), action: commitName).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .font(.callout)
    }

    private func commitName() {
        switch naming {
        case .saveAs: model.saveDraftAsNew(name: name)
        case .rename: model.rename(model.selectedID, to: name)
        case nil: break
        }
        naming = nil
    }
}
