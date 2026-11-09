import SwiftUI

struct DriverRoot: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let session = store.session {
                if session.user.mustSetPassword == true {
                    NavigationStack { PasswordView(forced: true) }
                } else {
                    TabView(selection: $store.tab) {
                        DriverTripsView(active: phase == .active && store.tab == 0)
                            .tabItem { Label("Trip", systemImage: "bus.fill") }.tag(0)
                        DriverRoutesView().tabItem { Label("Routes", systemImage: "map") }.tag(1)
                        DriverHistoryView().tabItem { Label("History", systemImage: "clock") }.tag(2)
                        ChatView(active: phase == .active && store.tab == 3)
                            .tabItem { Label("Messages", systemImage: "message") }.tag(3)
                        ProfileView().tabItem { Label("Profile", systemImage: "person") }.tag(4)
                    }
                }
            } else { LoginView() }
        }.tint(.blue).modifier(PushLifecycle())
    }
}
struct DriverTripsView: View {
    @EnvironmentObject var store: AppStore
    let active: Bool
    @State private var startTrip: Trip?
    @State private var ending = false
    var body: some View {
        NavigationStack {
            List {
                Section { Notices() }
                if !store.loaded.contains("driver") { ProgressView("Loading trips...") }
                if let trip = store.activeTrip {
                    Section("Active trip") {
                        TripSummary(trip: trip)
                        Text("Phase: \(trip.phase ?? "Unavailable")")
                        if let stats = trip.stats {
                            Text("Total \(stats.total ?? 0) - On bus \(stats.onBus ?? 0) - Dropped off \(stats.droppedOff ?? 0) - Absent \(stats.absent ?? 0)")
                        }
                        Button("End trip", role: .destructive) { ending = true }
                            .disabled(trip.canEnd != true || store.busy)
                        if trip.canEnd != true { Text("Resolve every student as dropped off or absent before ending.").font(.caption) }
                    }
                    if let stop = trip.currentStop {
                        Section(stop.phase == "dropoff" ? "Current drop-off" : "Current pickup") {
                            Text("#\(stop.stopNumber) \(stop.studentName)")
                            Text(stop.address ?? "Address unavailable")
                            if let coordinate = stop.coordinate { DestinationMap(coordinate: coordinate, title: stop.studentName) }
                            else { Text("The server has not provided a valid coordinate for this stop.").foregroundStyle(.secondary) }
                        }
                    }
                    if let next = trip.nextStop {
                        Section("Next stop") { Text(next.studentName); Text(next.address ?? "Address unavailable") }
                    }
                    Section("Tracking") { DriverTrackingPanel(trip: trip, location: store.location) }
                    Section("Students") {
                        ForEach(trip.pickupList ?? []) { stop in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("#\(stop.stopNumber) \(stop.studentName)").font(.headline)
                                Text(stop.status.replacingOccurrences(of: "_", with: " "))
                                Text(stop.pickupAddress ?? "")
                                if let phone = stop.parentPhone { PhoneLink(phone: phone, title: "Call \(stop.parentName ?? "parent")") }
                                ForEach(TripRules.actions(status: stop.status, tripPhase: trip.phase), id: \.self) { action in
                                    Button(actionLabel(action)) { Task { await store.action(action, student: stop, trip: trip) } }
                                        .disabled(store.busy)
                                }
                            }
                        }
                    }
                } else {
                    Section("Scheduled trips") {
                        if store.driverTrips.isEmpty && store.loaded.contains("driver") { Text("No trips scheduled today.") }
                        ForEach(store.driverTrips) { trip in
                            VStack(alignment: .leading) {
                                TripSummary(trip: trip)
                                if ["scheduled", "delayed"].contains(trip.status ?? "") {
                                    Button("Acknowledge and start") { startTrip = trip }.disabled(store.busy)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Driver trip")
            .refreshable { await store.refreshDriver() }
            .modifier(Polling(active: active, seconds: store.activeTrip == nil ? 30 : 15, refresh: store.refreshDriver))
            .confirmationDialog("Start this trip and notify parents?", isPresented: Binding(
                get: { startTrip != nil }, set: { if !$0 { startTrip = nil } })) {
                if let trip = startTrip {
                    Button("Acknowledge and start") { startTrip = nil; Task { await store.start(trip) } }
                }
            }
            .confirmationDialog("Complete this trip?", isPresented: $ending) {
                if let trip = store.activeTrip { Button("End trip", role: .destructive) { Task { await store.end(trip) } } }
            }
        }
    }
    private func actionLabel(_ action: String) -> String {
        switch action {
        case "check_in": return "Board student"
        case "check_out": return "Drop off student"
        case "absent": return "Mark absent"
        default: return "Record arrival"
        }
    }
}
struct DriverTrackingPanel: View {
    let trip: Trip
    @ObservedObject var location: LocationService
    var body: some View {
        if trip.usesTraccar {
            Text("Traccar tracker is authoritative. Phone sharing is off; an offline tracker does not enable fallback.")
        } else {
            Text(location.sharing ? "Phone GPS sharing enabled." : "Phone GPS sharing is not active.")
            if let notice = location.notice { Text(notice).font(.caption) }
            Button("Enable phone sharing") { location.resume(trip) }
            Button("Enable background GPS permission") { location.backgroundPermission() }
            Button("Pause phone sharing") { location.pause() }.disabled(!location.sharing)
        }
    }
}
struct DriverRoutesView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationStack {
            List {
                Section { Notices() }
                if !store.loaded.contains("routes") { ProgressView("Loading routes...") }
                if store.routes.isEmpty && store.loaded.contains("routes") { Text("No assigned routes.") }
                ForEach(store.routes) { route in
                    DisclosureGroup(route.name ?? "Route") {
                        Text(route.vehicle?.plateNumber ?? "Vehicle not assigned")
                        ForEach(route.students ?? []) { student in
                            Text("\(student.fullName) - \(student.grade ?? "")")
                            if let parent = student.parent, let phone = parent.phone { PhoneLink(phone: phone, title: "Call \(parent.fullName)") }
                        }
                    }
                }
            }
            .navigationTitle("Routes").task { await store.refreshRoutes() }
            .refreshable { await store.refreshRoutes() }
        }
    }
}
struct DriverHistoryView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationStack {
            List {
                Section { Notices() }
                if !store.loaded.contains("driverHistory") { ProgressView("Loading history...") }
                if store.driverHistory.isEmpty && store.loaded.contains("driverHistory") { Text("No trips in the last 30 days.") }
                ForEach(store.driverHistory) { trip in
                    DisclosureGroup {
                        TripSummary(trip: trip)
                        ForEach(trip.pickupList ?? []) { stop in Text("\(stop.studentName): \(stop.status)") }
                    } label: { TripSummary(trip: trip) }
                }
            }
            .navigationTitle("Trip history").task { await store.refreshDriverHistory() }
            .refreshable { await store.refreshDriverHistory() }
        }
    }
}
