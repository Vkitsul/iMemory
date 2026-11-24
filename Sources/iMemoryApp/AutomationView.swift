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
    init(file: URL = AppStorage.folder.appendingPathComponent("automation.json"), notifies: Bool = true) {
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
                title: "Disk space is running low",
                body: "\(Format.bytes(free)) left. Open iMemory to see what you can free."
            )
        }
    }

    var isCleanupDue: Bool {
        ScheduledCleanup.isDue(settings: settings, now: .now)
    }

    func recordScheduledCleanup(_ report: CleanupReport) {
        update { $0.lastScheduledCleanup = report.date }
        notify(
            title: "Scheduled cleanup done",
            body: "Deleted \(Format.items(report.removedItemCount)). Details are in History."
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
            Section("Menu bar") {
                Toggle("Show the icon in the menu bar", isOn: Binding(
                    get: { model.settings.showsMenuBarIcon },
                    set: { value in model.update { $0.showsMenuBarIcon = value } }
                ))
            }

            Section {
                Toggle("Warn me when space runs low", isOn: Binding(
                    get: { model.settings.warnsOnLowSpace },
                    set: { model.enableWarnings($0) }
                ))
                Stepper(value: Binding(
                    get: { model.settings.lowSpaceThresholdGB },
                    set: { value in model.update { $0.lowSpaceThresholdGB = value } }
                ), in: 5...200, step: 5) {
                    LabeledContent("Below", value: "\(model.settings.lowSpaceThresholdGB) GB")
                }
                .disabled(!model.settings.warnsOnLowSpace)
                if model.notificationsDenied {
                    Text("macOS doesn't allow notifications from iMemory. The menu bar icon still changes. You can turn them on in System Settings, Notifications.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Disk space")
            } footer: {
                Text("Free now: \(Format.bytes(model.free)). You're warned once, and again only after space has gone back above the threshold.")
            }

            Section {
                Toggle("Clean safe items automatically", isOn: Binding(
                    get: { model.settings.cleansOnSchedule },
                    set: { value in model.update { $0.setCleansOnSchedule(value) } }
                ))
                Picker("Frequency", selection: Binding(
                    get: { model.settings.interval },
                    set: { value in model.update { $0.interval = value } }
                )) {
                    Text("Every week").tag(AutomationSettings.Interval.weekly)
                    Text("Every month").tag(AutomationSettings.Interval.monthly)
                }
                .disabled(!model.settings.cleansOnSchedule)
                if let last = model.settings.lastScheduledCleanup {
                    LabeledContent("Last cleanup", value: Format.dateTime(last))
                }
            } header: {
                Text("Scheduled cleanup")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Deletes without asking, and doesn't use the Trash. The first cleanup happens a full interval after you turn it on, and only while iMemory is open. Every run is recorded in History.")
                    Text(eligible.isEmpty
                        ? "Right now there would be nothing to delete."
                        : "Right now it would delete: \(eligible.map { "\($0.rule.title) (\(Format.bytes($0.allocated)))" }.joined(separator: ", ")).")
                    Text("It never touches apps, personal files, tool commands, or items to review.")
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
        Text("\(Format.bytes(model.automation.free)) free")
        if model.automation.isLow {
            Text("Running low on space")
        }
        Divider()
        Button("Open iMemory") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Go to Cleanup") {
            model.section = .cleanup
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
