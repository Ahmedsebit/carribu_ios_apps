import SwiftUI
import MapKit

struct ParentRoot: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let session = store.session {
                if session.user.mustSetPassword == true {
                    NavigationStack { PasswordView(forced: true) }
                } else {
                    TabView(selection: $store.tab) {
                        TrackingView(active: phase == .active && store.tab == 0)
                            .tabItem { Label("Track", systemImage: "bus.fill") }.tag(0)
                        ParentTripsView().tabItem { Label("Trips", systemImage: "calendar") }.tag(1)
                        AlertsView(active: phase == .active && store.tab == 2)
                            .tabItem { Label("Alerts", systemImage: "bell") }.tag(2)
                        ChatView(active: phase == .active && store.tab == 3)
                            .tabItem { Label("Messages", systemImage: "message") }.tag(3)
                        ProfileView().tabItem { Label("Profile", systemImage: "person") }.tag(4)
                    }
                }
            } else { LoginView() }
        }.tint(.blue).modifier(PushLifecycle())
    }
}
struct TrackingView: View {
    @EnvironmentObject var store: AppStore
    let active: Bool
    @State private var showMap = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Notices()
                    Toggle("Map view", isOn: $showMap)
                    Text("Checks for updates every 10 seconds while this screen is active.")
                }
                if !store.loaded.contains("buses") { ProgressView("Finding active buses...") }
                if store.buses.isEmpty && store.loaded.contains("buses") { Text("No active buses. Trips appear after the driver starts.") }
                if showMap {
                    if store.buses.count > 1 {
                        Picker("Bus", selection: $store.selectedBus) {
                            ForEach(store.buses) { bus in Text(bus.routeName).tag(Optional(bus.id)) }
                        }
                    }
                    if let bus = store.buses.first(where: { $0.tripId == store.selectedBus }) {
                        BusCard(bus: bus, showMap: true)
                    }
                } else {
                    ForEach(store.buses) { bus in BusCard(bus: bus, showMap: false) }
                }
            }
            .navigationTitle("Bus tracking")
            .refreshable { await store.refreshBuses() }
            .modifier(Polling(active: active, seconds: 10, refresh: store.refreshBuses))
        }
    }
}
struct BusCard: View {
    let bus: ActiveBus
    let showMap: Bool
    var body: some View {
        Section(bus.routeName) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(alignment: .leading, spacing: 8) {
                    Text(bus.location?.fresh(now: timeline.date) == true ? "LIVE" : "LAST KNOWN / WAITING FOR GPS")
                        .font(.caption.bold())
                    Text("\(bus.tripType.replacingOccurrences(of: "_", with: " ")) - \(bus.phase ?? "Phase unavailable")")
                    if let school = bus.routeSchool { Text(school) }
                    Text(bus.vehicle?.plateNumber ?? "Vehicle pending")
                    Text("GPS fix: \(bus.location?.recordedAt ?? "Unavailable")").font(.caption)
                    if bus.location?.fresh(now: timeline.date) != true { Text("Location is not fresh. Arrival estimates are hidden.").font(.caption) }
                    ForEach(bus.children ?? []) { child in
                        Text("\(child.firstName) \(child.lastName ?? ""): \(child.status ?? "Status unavailable")")
                        if bus.showETA(now: timeline.date), let eta = child.eta {
                            if eta.alreadyPickedUp == true { Text("Already boarded") }
                            else if let minutes = eta.totalMinutes { Text("About \(minutes) minutes; approximate, not road-routed.") }
                        }
                    }
                }
            }
            if showMap {
                if let point = bus.location?.coordinate {
                    BusMap(bus: bus, point: point)
                } else { Text("Waiting for a valid authoritative GPS fix.").foregroundStyle(.secondary) }
            }
            if let driver = bus.driver {
                Text(driver.fullName)
                if let phone = driver.phone { PhoneLink(phone: phone, title: "Call driver") }
            }
        }
    }
}
struct BusMap: View {
    let bus: ActiveBus
    let point: Coordinate
    @State private var camera: MapCameraPosition = .automatic
    var stops: [PendingStop] { (bus.pendingStops ?? []).filter { $0.coordinate != nil }.sorted { $0.stopOrder < $1.stopOrder } }
    var body: some View {
        Map(position: $camera) {
            Marker(bus.routeName, systemImage: "bus.fill", coordinate: point.mapCoordinate).tint(.blue)
            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                if let coordinate = stop.coordinate {
                    Marker(stop.isMyChild == true ? "\(stop.firstName ?? "Child")'s stop" : "Stop \(stop.stopOrder)",
                           coordinate: coordinate.mapCoordinate).tint(stop.isMyChild == true ? .green : .orange)
                }
            }
            if !stops.isEmpty {
                MapPolyline(coordinates: [point.mapCoordinate] + stops.compactMap { $0.coordinate?.mapCoordinate })
                    .stroke(.blue, lineWidth: 3)
            }
        }
        .frame(height: 300)
        .onChange(of: point) { _, value in
            camera = .region(.init(center: value.mapCoordinate, span: .init(latitudeDelta: 0.025, longitudeDelta: 0.025)))
        }
        .id(bus.id)
    }
}
struct ParentTripsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showHistory = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Notices()
                    Toggle("Completed history", isOn: $showHistory)
                    Picker("School", selection: Binding(get: { store.schoolID }, set: { id in
                        store.selectSchool(id); Task { await store.refreshParentTrips() }
                    })) {
                        Text("All schools").tag(nil as Int?)
                        ForEach(store.filters?.schools ?? []) { school in Text(school.name).tag(Optional(school.id)) }
                    }
                    Picker("Student", selection: Binding(get: { store.studentID }, set: { id in
                        store.studentID = id; Task { await store.refreshParentTrips() }
                    })) {
                        Text("All children").tag(nil as Int?)
                        ForEach((store.filters?.students ?? []).filter { store.schoolID == nil || $0.schoolId == store.schoolID }) { child in
                            Text(child.fullName).tag(Optional(child.id))
                        }
                    }
                }
                if !store.loaded.contains("parentTrips") { ProgressView("Loading trips...") }
                if (showHistory ? store.history : store.upcoming).isEmpty && store.loaded.contains("parentTrips") {
                    Text(showHistory ? "No completed trips in the last 30 days." : "No trips in the next 7 days.")
                }
                ForEach(showHistory ? store.history : store.upcoming) { trip in
                    DisclosureGroup {
                        TripSummary(trip: trip)
                        ForEach(trip.children ?? []) { child in Text("\(child.studentName): \(child.status ?? "Status unavailable")") }
                        if let driver = trip.driver, let phone = driver.phone { PhoneLink(phone: phone, title: "Call \(driver.fullName)") }
                    } label: { TripSummary(trip: trip) }
                }
            }
            .navigationTitle("Trips and history").task { await store.refreshParentTrips() }
            .refreshable { await store.refreshParentTrips() }
        }
    }
}
struct AlertsView: View {
    @EnvironmentObject var store: AppStore
    let active: Bool
    @State private var clear = false
    var body: some View {
        NavigationStack {
            List {
                Section { Notices() }
                if !store.loaded.contains("alerts") { ProgressView("Loading alerts...") }
                if store.notifications.isEmpty && store.loaded.contains("alerts") { Text("No alerts.") }
                ForEach(store.notifications) { alert in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(alert.messageType?.replacingOccurrences(of: "_", with: " ") ?? "Alert").font(.caption.bold())
                        Text(alert.content)
                        Text(alert.createdAt ?? "").font(.caption2)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { Task { await store.removeAlert(alert.id) } } }
                }
            }
            .navigationTitle("Alerts")
            .toolbar { Button("Clear", role: .destructive) { clear = true } }
            .confirmationDialog("Clear all notifications?", isPresented: $clear) {
                Button("Clear all", role: .destructive) { Task { await store.removeAlert(nil) } }
            }
            .refreshable { await store.refreshAlerts() }
            .modifier(Polling(active: active, seconds: 20, refresh: store.refreshAlerts))
        }
    }
}
