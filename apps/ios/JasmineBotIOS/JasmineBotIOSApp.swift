import SwiftUI
import UserNotifications
import JasmineMobileCore

@main
struct JasmineBotIOSApp: App {
    @State private var store = AppStoreModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if store.credentials == nil {
                    PairingView(store: store)
                } else {
                    MainTabView(store: store)
                }
            }
            .onOpenURL { url in
                Task {
                    await store.handleDeepLink(url)
                }
            }
        }
    }
}
