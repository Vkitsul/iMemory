import AppKit
import CleanKit
import Observation
import RulesKit
import ScanKit
import SwiftUI
import UserNotifications

/// Free space, the low-space warning, and the settings for what runs by itself.
@Observable
final class AutomationModel {
    private(set) var settings: AutomationSettings
    private(set) var free: Int64 = 0
    private(set) var isLow = false
    private(set) var notificationsDenied = false
    private var watch: SpaceWatch
    private let file: URL
    private let notifies: Bool

    /// - Parameter notifies: Off in the self-check, which must not ask for permissions.
    init(file: URL = AppStorage.folder.appendingPathComponent("automazione.json"), notifies: Bool = true) {
        self.file = file
        self.notifies = notifies
        let loaded = AutomationSettings.load(from: file)
        settings = loaded
        watch = SpaceWatch(threshold: Int64(loaded.lowSpaceThresholdGB) * 1_000_000_000)
    }

    /// Does nothing if nothing changes. Views call this while drawing can be underway, and a
    /// write with no change would redraw them and call it again, without end.
    func update(_ change: (inout AutomationSettings) -> Void) {
        var changed = settings
        change(&changed)
        guard changed != settings else { return }

        settings = changed
        watch.threshold = Int64(settings.lowSpaceThresholdGB) * 1_000_000_000
        try? settings.save(to: file)
        refreshSpace()
    }

    func enableWarnings(_ isOn: Bool) {
        update { $0.warnsOnLowSpace = isOn }
        guard isOn, notifies else { return }
        Task {
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            notificationsDenied = granted != true
        }
    }

    func refreshSpace() {
        guard let capacity = try? VolumeCapacity(path: AppModel.scanRoot) else { return }
        if free != capacity.available {
            free = capacity.available
        }
        let low = watch.isLow(free: capacity.available)
        if isLow != low {
            isLow = low
        }
        if watch.shouldWarn(free: capacity.available), settings.warnsOnLowSpace {
            notify(
                title: "Spazio su disco in esaurimento",
                body: "Restano \(Format.bytes(free)). Apri iMemory per vedere cosa puoi liberare."
            )
        }
    }

    var isCleanupDue: Bool {
        ScheduledCleanup.isDue(settings: settings, now: .now)
    }

    func recordScheduledCleanup(_ report: CleanupReport) {
        update { $0.lastScheduledCleanup = report.date }
        notify(
            title: "Pulizia programmata eseguita",
            body: "\(Format.items(report.removedItemCount)) eliminate. I dettagli sono in Cronologia."
        )
    }

    private func notify(title: String, body: String) {
        guard notifies else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

struct AutomationView: View {
    @Bindable var model: AutomationModel
    /// What a scheduled cleanup would remove now.
    let eligible: [CleanupCandidate]

    var body: some View {
        Form {
            Section("Barra dei menu") {
                Toggle("Mostra l'icona nella barra dei menu", isOn: Binding(
                    get: { model.settings.showsMenuBarIcon },
                    set: { value in model.update { $0.showsMenuBarIcon = value } }
                ))
            }

            Section {
                Toggle("Avvisami quando lo spazio è poco", isOn: Binding(
                    get: { model.settings.warnsOnLowSpace },
                    set: { model.enableWarnings($0) }
                ))
                Stepper(value: Binding(
                    get: { model.settings.lowSpaceThresholdGB },
                    set: { value in model.update { $0.lowSpaceThresholdGB = value } }
                ), in: 5...200, step: 5) {
                    LabeledContent("Sotto questa soglia", value: "\(model.settings.lowSpaceThresholdGB) GB")
                }
                .disabled(!model.settings.warnsOnLowSpace)
                if model.notificationsDenied {
                    Text("macOS non consente le notifiche a iMemory. L'icona nella barra dei menu cambia comunque. Puoi attivarle in Impostazioni di Sistema, Notifiche.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Spazio su disco")
            } footer: {
                Text("Ora liberi: \(Format.bytes(model.free)). L'avviso arriva una volta sola, e di nuovo solo dopo che lo spazio è tornato sopra la soglia.")
            }

            Section {
                Toggle("Pulisci automaticamente le voci sicure", isOn: Binding(
                    get: { model.settings.cleansOnSchedule },
                    set: { value in model.update { $0.setCleansOnSchedule(value) } }
                ))
                Picker("Frequenza", selection: Binding(
                    get: { model.settings.interval },
                    set: { value in model.update { $0.interval = value } }
                )) {
                    Text("Ogni settimana").tag(AutomationSettings.Interval.weekly)
                    Text("Ogni mese").tag(AutomationSettings.Interval.monthly)
                }
                .disabled(!model.settings.cleansOnSchedule)
                if let last = model.settings.lastScheduledCleanup {
                    LabeledContent("Ultima pulizia", value: Format.dateTime(last))
                }
            } header: {
                Text("Pulizia programmata")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Elimina senza chiedere, e non passa dal Cestino. La prima pulizia avviene dopo un intero intervallo dall'attivazione, e solo mentre iMemory è aperta. Ogni esecuzione finisce in Cronologia.")
                    Text(eligible.isEmpty
                        ? "Ora non ci sarebbe niente da eliminare."
                        : "Ora eliminerebbe: \(eligible.map { "\($0.rule.title) (\(Format.bytes($0.allocated)))" }.joined(separator: ", ")).")
                    Text("Non riguarda mai app, file personali, comandi degli strumenti o voci da valutare.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshSpace() }
    }
}

/// The menu shown from the icon in the menu bar.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(Format.bytes(model.automation.free)) liberi")
        if model.automation.isLow {
            Text("Spazio in esaurimento")
        }
        Divider()
        Button("Apri iMemory") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Vai a Pulizia") {
            model.section = .cleanup
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Esci") {
            NSApp.terminate(nil)
        }
    }
}
