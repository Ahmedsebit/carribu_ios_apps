import SwiftUI

@main
struct CarribuParentApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var delegate
    @StateObject private var store = AppStore(kind: .parent)
    var body: some Scene {
        WindowGroup { ParentRoot().environmentObject(store) }
    }
}
