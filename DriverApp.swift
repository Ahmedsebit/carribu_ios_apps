import SwiftUI

@main
struct CarribuDriverApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var delegate
    @StateObject private var store = AppStore(kind: .driver)
    var body: some Scene {
        WindowGroup { DriverRoot().environmentObject(store) }
    }
}
