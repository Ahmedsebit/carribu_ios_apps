import SwiftUI
import CoreLocation
import MapKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var position: Coordinate?
    @Published var notice: String?
    @Published var sharing = false
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    var upload: ((Int, Coordinate, Double?, Double?) async throws -> Void)?
    private let manager = CLLocationManager()
    private let driver: Bool
    private var tripID: Int?
    private var pausedTripID: Int?
    private var uploading = false
    private var lastUpload = Date.distantPast
    private var oneOff = false

    init(driver: Bool) {
        self.driver = driver
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        authorization = manager.authorizationStatus
    }
    func configure(_ trip: Trip?) {
        guard driver else { return }
        guard let trip, !trip.usesTraccar else {
            stop()
            notice = trip?.usesTraccar == true ? "Linked Traccar tracker: phone sharing is off." : nil
            return
        }
        if tripID != trip.id { stop(); tripID = trip.id; lastUpload = .distantPast }
        if pausedTripID == trip.id { return }
        start()
    }
    func start() {
        guard driver, tripID != nil else { return }
        pausedTripID = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
            manager.showsBackgroundLocationIndicator = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.startUpdatingLocation()
            sharing = true
            notice = manager.authorizationStatus == .authorizedAlways
                ? "Phone GPS sharing is active, including background updates."
                : "Phone GPS sharing is active while in use. Enable background access for background sharing."
        case .denied, .restricted:
            sharing = false
            notice = "Location permission is denied. Enable it in Settings to share this unlinked vehicle's location."
        @unknown default: notice = "Location authorization is unavailable."
        }
    }
    func resume(_ trip: Trip) {
        pausedTripID = nil
        configure(trip)
    }
    func backgroundPermission() {
        guard driver, tripID != nil else { return }
        manager.requestAlwaysAuthorization()
    }
    func pause() {
        pausedTripID = tripID
        stop()
        notice = "Phone GPS sharing paused. Parents will see the last known location."
    }
    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        sharing = false
        tripID = nil
    }
    func currentPosition() {
        oneOff = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: notice = "Allow location access in Settings, or choose the pickup point on the map."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if oneOff, authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.requestLocation()
        }
        if tripID != nil && tripID != pausedTripID { start() }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        notice = "GPS unavailable: \(error.localizedDescription)"
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              TripRules.freshAge(Date().timeIntervalSince(location.timestamp)),
              let point = Coordinate.valid(location.coordinate.latitude, location.coordinate.longitude) else {
            notice = "Waiting for a valid recent phone GPS fix."
            return
        }
        position = point
        oneOff = false
        guard sharing, let id = tripID, !uploading, Date().timeIntervalSince(lastUpload) >= 5 else { return }
        guard let upload else { notice = "GPS upload is not configured."; return }
        uploading = true
        lastUpload = Date()
        Task {
            defer { uploading = false }
            do {
                guard tripID == id, sharing else { return }
                try await upload(id, point, location.speed >= 0 ? location.speed * 3.6 : nil,
                                 location.course >= 0 ? location.course : nil)
                if tripID == id { notice = "Phone GPS fix shared." }
            } catch is CancellationError {}
            catch {
                guard tripID == id else { return }
                if let failure = error as? AppFailure, [401, 404, 409].contains(failure.status ?? 0) {
                    pausedTripID = id
                    stop()
                }
                notice = "GPS upload failed: \(error.localizedDescription)"
            }
        }
    }
}
@MainActor
final class PushService: ObservableObject {
    static let shared = PushService()
    @Published var token: String?
    @Published var apnsReady = false
    @Published var notice: String?
    @Published var tapped = UUID()
    private var events: [String] = []
    func prepare() async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw AppFailure("Add this app's GoogleService-Info.plist and configure APNs before enabling notifications.")
        }
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) else {
            throw AppFailure("Notification permission was denied. Enable it in Settings.")
        }
        UIApplication.shared.registerForRemoteNotifications()
        guard apnsReady else { throw AppFailure("Waiting for APNs registration; token registration will retry when APNs is ready.") }
        return try await Messaging.messaging().token()
    }
    func seen(_ event: String?) -> Bool {
        guard let event else { return false }
        if events.contains(event) { return true }
        events.append(event)
        if events.count > 200 { events.removeFirst() }
        return false
    }
    func clear() {
        events = []
        notice = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
}
final class PushDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
        }
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard FirebaseApp.app() != nil else { return }
        Messaging.messaging().apnsToken = deviceToken
        Task { @MainActor in PushService.shared.apnsReady = true }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushService.shared.notice = "APNs registration failed: \(error.localizedDescription)" }
    }
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in PushService.shared.token = fcmToken }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let event = notification.request.content.userInfo["eventId"] as? String
        Task { @MainActor in
            completionHandler(PushService.shared.seen(event) ? [] : [.banner, .sound, .badge])
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in PushService.shared.tapped = UUID(); completionHandler() }
    }
}
