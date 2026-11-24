import SwiftUI

@main
struct iMemoryApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("iMemory", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    model.startAutomation()
                    model.startScan()
                    if let output = ProcessInfo.processInfo.environment["IMEMORY_SELFCHECK"] {
                        await SelfCheck(model: model, output: output).run()
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)

        // Read-only: the setting belongs to the Automation section. If the system wrote to it,
        // such as when the app quits, the icon could turn itself off for good.
        MenuBarExtra(isInserted: Binding(
            get: { model.automation.settings.showsMenuBarIcon },
            set: { _ in }
        )) {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.automation.isLow ? "externaldrive.badge.exclamationmark" : "internaldrive")
        }
    }
}
