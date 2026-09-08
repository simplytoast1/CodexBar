import CodexBarCore
import SwiftUI

/// Links a phone to CodexBar and chooses what it shows.
///
/// The pane owns every user-visible decision this feature has: the credentials,
/// which of the four surfaces are on, which providers fill the tile, and which
/// single window the Lock Screen gauge draws. Publishing itself belongs to
/// `NotifyPublishDriver`, which holds the stored handles and the single
/// in-flight write, so "Publish Now" asks the driver rather than publishing for
/// itself — two publishers racing over one nil activity id is how a phone ends
/// up with two Live Activities.
@MainActor
struct NotifyPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    @State private var deviceIDField = ""
    @State private var tokenField = ""
    @State private var status: Status = .idle
    @State private var isWorking = false
    @State private var hasStoredToken = false

    /// What the pane is currently telling the user, if anything.
    private enum Status: Equatable {
        case idle
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            self.linkSection
            if self.isLinked {
                self.surfacesSection
                self.tileContentSection
                self.gaugeSection
            }
            self.privacySection
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
        .onAppear {
            self.deviceIDField = self.settings.notifyDeviceID
            // The token is never read back into the field. It lives in the Keychain, and a pane
            // that displayed it would put a secret on screen for no gain: the user already has it
            // in the Notify! app, and the only thing they can usefully do here is replace it.
            self.tokenField = ""
            self.hasStoredToken = self.settings.notifyDeviceToken() != nil
        }
    }

    // MARK: - Link

    private var linkSection: some View {
        Section {
            Toggle(isOn: self.$settings.notifyEnabled) {
                SettingsRowLabel(
                    L("notify_enabled_title"),
                    subtitle: L("notify_enabled_subtitle"))
            }
            .disabled(!self.isLinked)

            TextField(L("notify_device_id_field"), text: self.$deviceIDField)
                .textFieldStyle(.roundedBorder)
                .onChange(of: self.deviceIDField) { _, newValue in
                    // The Notify! app offers a whole notification URL as well as the two bare
                    // values, so whatever the user actually has on the clipboard is accepted.
                    guard let recovered = NotifyDeviceLink.deviceId(inPastedText: newValue),
                          recovered != newValue
                    else { return }
                    self.deviceIDField = recovered
                    if let link = NotifyDeviceLink(pastedText: newValue) {
                        self.tokenField = link.token
                    }
                }

            SecureField(L("notify_device_token_field"), text: self.$tokenField)
                .textFieldStyle(.roundedBorder)

            if let kind = self.linkKind {
                SettingsRowLabel(
                    L("notify_linked_device_title"),
                    subtitle: kind.displayName)
            }

            HStack {
                Button(L("notify_save_button")) { self.save() }
                    .disabled(self.isWorking || !self.canSave)
                Button(L("notify_verify_button")) { Task { await self.verify() } }
                    .disabled(self.isWorking || !self.canSave)
                Button(L("notify_publish_now_button")) { Task { await self.publishNow() } }
                    .disabled(self.isWorking || !self.isLinked)
                Spacer()
                if self.isLinked {
                    Button(L("notify_unlink_button"), role: .destructive) { self.unlink() }
                        .disabled(self.isWorking)
                }
            }

            switch self.status {
            case .idle:
                EmptyView()
            case let .success(message):
                Text(message).font(.callout).foregroundStyle(.green)
            case let .failure(message):
                Text(message).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text(L("notify_section_device"))
        } footer: {
            SettingsSectionFooter {
                Text(L("notify_section_device_footer"))
            }
        }
    }

    // MARK: - Surfaces

    private var surfacesSection: some View {
        Section {
            Toggle(isOn: self.$settings.notifyLiveActivityEnabled) {
                SettingsRowLabel(
                    L("notify_live_activity_title"),
                    // A Mac link and a browser link cannot start a Live Activity. Saying which
                    // device it is beats letting the gateway answer with a 400 that reads as
                    // CodexBar failing at something it should have managed.
                    subtitle: self.linkKind?.liveActivityUnsupportedReason
                        ?? L("notify_live_activity_subtitle"))
            }
            .disabled(self.linkKind?.supportsLiveActivity == false)

            Toggle(isOn: self.$settings.notifyWidgetEnabled) {
                SettingsRowLabel(
                    L("notify_widget_title"),
                    subtitle: self.linkKind?.widgetUnsupportedReason ?? L("notify_widget_subtitle"))
            }
            .disabled(self.linkKind?.supportsWidget == false)

            Toggle(isOn: self.$settings.notifyScreenWidgetEnabled) {
                SettingsRowLabel(
                    L("notify_screen_widget_title"),
                    subtitle: self.linkKind?.screenWidgetUnsupportedReason
                        ?? L("notify_screen_widget_subtitle"))
            }
            .disabled(self.linkKind?.supportsScreenWidget == false)

            Toggle(isOn: self.$settings.notifyNotificationsEnabled) {
                SettingsRowLabel(
                    L("notify_alerts_title"),
                    subtitle: L("notify_alerts_subtitle"))
            }
        } header: {
            Text(L("notify_section_surfaces"))
        }
    }

    // MARK: - What the tile shows

    private var tileContentSection: some View {
        Section {
            ForEach(self.availableInstances) { candidate in
                Toggle(isOn: self.instanceBinding(for: candidate.instanceID)) {
                    Text(candidate.name)
                }
            }
        } header: {
            Text(L("notify_section_tile_content"))
        } footer: {
            SettingsSectionFooter {
                Text(L("notify_section_tile_content_footer", NotifyLimits.metricCount))
            }
        }
    }

    // MARK: - Gauge

    private var gaugeSection: some View {
        Section {
            Picker(L("notify_gauge_window"), selection: self.gaugeBinding) {
                Text(L("notify_gauge_automatic")).tag(NotifyGaugeSelection.automatic)
                ForEach(self.availableReadings, id: \.self) { reading in
                    Text("\(reading.providerName) \(reading.windowLabel)")
                        .tag(NotifyGaugeSelection(
                            instanceID: reading.instanceID.rawValue,
                            quotaKey: reading.quotaKey))
                }
            }
        } header: {
            Text(L("notify_section_gauge"))
        } footer: {
            SettingsSectionFooter {
                Text(L("notify_section_gauge_footer"))
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            SettingsRowLabel(
                L("notify_privacy_title"),
                subtitle: L("notify_privacy_subtitle"))
        } header: {
            Text(L("notify_section_privacy"))
        }
    }

    // MARK: - State

    /// Whether both halves of the link are on file.
    ///
    /// Reads `hasStoredToken` rather than asking the Keychain, because this is
    /// evaluated on every render and a Keychain query per render is both wasteful
    /// and, on a machine whose Keychain is locked, a way to earn a prompt the
    /// user did not ask for. The flag is refreshed when the pane appears and
    /// after every action that could change it.
    private var isLinked: Bool {
        self.hasStoredToken && NotifyDeviceLink.isValidDeviceId(self.settings.notifyDeviceID)
    }

    private var linkKind: NotifyDeviceKind? {
        let identifier = self.settings.notifyDeviceID
        guard NotifyDeviceLink.isValidDeviceId(identifier) else { return nil }
        return NotifyDeviceKind.kind(ofDeviceId: identifier)
    }

    private var canSave: Bool {
        NotifyDeviceLink(
            deviceId: self.deviceIDField,
            token: self.tokenField.isEmpty ? "placeholder" : self.tokenField) != nil
    }

    /// The quota windows currently on offer, which is what both pickers list.
    ///
    /// `lastQueuedWidgetSnapshot` is deliberately `@ObservationIgnored` on the
    /// store, so reading it alone would leave these lists frozen at whatever
    /// they held when the pane opened. Touching `snapshots` first registers the
    /// observation that actually moves on a refresh, which is the property the
    /// widget snapshot is built from anyway.
    private var availableReadings: [NotifyQuotaReading] {
        _ = self.store.snapshots.count
        guard let snapshot = self.store.lastQueuedWidgetSnapshot else { return [] }
        return NotifyReadingsBuilder.readings(
            from: snapshot,
            pluginNames: UsageStore.notifyPluginNames())
    }

    /// One row per provider instance reporting anything, in a stable order.
    private struct InstanceRow: Identifiable, Hashable {
        let instanceID: ProviderInstanceID
        let name: String

        var id: ProviderInstanceID {
            self.instanceID
        }
    }

    private var availableInstances: [InstanceRow] {
        var seen = Set<ProviderInstanceID>()
        return self.availableReadings.compactMap { reading in
            guard seen.insert(reading.instanceID).inserted else { return nil }
            return InstanceRow(instanceID: reading.instanceID, name: reading.providerName)
        }
    }

    private func instanceBinding(for instanceID: ProviderInstanceID) -> Binding<Bool> {
        Binding(
            get: {
                let selection = self.settings.notifyInstanceSelection
                // Automatic means every instance is eligible, so every row reads as on.
                return selection.isAutomatic || selection.instanceIDs.contains(instanceID.rawValue)
            },
            set: { isOn in
                var identifiers = self.settings.notifyInstanceSelection.instanceIDs
                if identifiers.isEmpty {
                    // Turning one off out of "automatic" has to name the rest explicitly, or the
                    // selection would stay automatic and the toggle would spring back.
                    identifiers = self.availableInstances.map(\.instanceID.rawValue)
                }
                if isOn {
                    if !identifiers.contains(instanceID.rawValue) { identifiers.append(instanceID.rawValue) }
                } else {
                    identifiers.removeAll { $0 == instanceID.rawValue }
                }
                self.settings.notifyInstanceSelection = NotifyInstanceSelection(instanceIDs: identifiers)
            })
    }

    private var gaugeBinding: Binding<NotifyGaugeSelection> {
        Binding(
            get: { self.settings.notifyGaugeSelection },
            set: { self.settings.notifyGaugeSelection = $0 })
    }

    // MARK: - Actions

    private func save() {
        let identifier = self.deviceIDField.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            self.settings.notifyDeviceID = identifier
            if !self.tokenField.isEmpty {
                try self.settings.setNotifyDeviceToken(self.tokenField)
                self.tokenField = ""
            }
            guard self.settings.notifyDeviceLink() != nil else {
                self.status = .failure(L("notify_status_needs_both"))
                return
            }
            self.hasStoredToken = self.settings.notifyDeviceToken() != nil
            self.settings.notifyEnabled = true
            self.status = .success(L("notify_status_saved"))
        } catch {
            self.status = .failure(error.localizedDescription)
        }
    }

    /// Asks the gateway to describe the linked device.
    ///
    /// The gateway rate limits this route to five calls a minute, so it lives
    /// behind this button and nothing else. Nothing on a timer may call it.
    private func verify() async {
        guard let link = self.settings.notifyDeviceLink() else {
            self.status = .failure(L("notify_status_needs_both"))
            return
        }
        self.isWorking = true
        defer { self.isWorking = false }
        do {
            let info = try await NotifyGatewayClient().deviceInfo(link: link)
            self.status = .success(L("notify_status_verified", info.displayDescription))
        } catch {
            self.status = .failure(
                (error as? NotifyPublishError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Publishes right now, bypassing the gate.
    ///
    /// Waiting a quarter of an hour to find out whether a token works would not
    /// be an answer, so this exists and goes through the driver.
    private func publishNow() async {
        self.isWorking = true
        defer { self.isWorking = false }
        if let failure = await self.store.notifyPublishDriver().publishNow() {
            self.status = .failure(failure)
        } else {
            self.status = .success(L("notify_status_published"))
        }
    }

    private func unlink() {
        // The token goes first: if clearing the Keychain fails, the settings still name a device
        // whose token is gone, which reads as a refused credential rather than a silent stop.
        try? self.settings.setNotifyDeviceToken(nil)
        self.settings.notifyEnabled = false
        self.settings.notifyDeviceID = ""
        self.hasStoredToken = false
        self.deviceIDField = ""
        self.tokenField = ""
        self.status = .success(L("notify_status_unlinked"))
    }
}
