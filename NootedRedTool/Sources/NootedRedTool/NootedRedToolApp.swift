import SwiftUI

@main
struct NootedRedToolApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("重新检查") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                ForEach(AppPage.allCases, id: \.self) { page in
                    Button(page.title) { model.selectedPage = page }
                }
            }
        }
    }
}
