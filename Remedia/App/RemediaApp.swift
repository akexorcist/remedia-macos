import SwiftUI

@main
struct RemediaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = ConversionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear { appDelegate.viewModel = viewModel }
        }
        .defaultSize(width: 360, height: 270)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Remedia") {
                    AppDelegate.showAboutPanel()
                }
            }
        }
    }
}
