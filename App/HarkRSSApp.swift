import SwiftUI

@main
struct HarkRSSApp: App {
    @StateObject private var store = FeedStore()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(store) }
    }
}
