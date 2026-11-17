import SwiftUI

@main
struct ReadlingApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.accent)
        }
    }
}

extension URL {
    /// Everything the app keeps: the library, books, downloaded dictionaries and the reader's background.
    static let appData = URL.applicationSupportDirectory.appendingPathComponent("Readling", isDirectory: true)
}
