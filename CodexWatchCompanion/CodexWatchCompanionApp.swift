import SwiftUI

@main
struct CodexWatchCompanionApp: App {
    @StateObject private var model = CompanionViewModel()

    var body: some Scene {
        WindowGroup {
            CompanionRootView(model: model)
                .onAppear {
                    let process = ProcessInfo.processInfo
                    if process.arguments.contains("--ui-testing") {
                        model.applyUITestScenario(process.environment["CODEX_WATCH_UI_TEST_SCENARIO"])
                    } else {
                        model.startRuntimeSession()
                        model.connectIfPossible()
                    }
                }
        }
    }
}
