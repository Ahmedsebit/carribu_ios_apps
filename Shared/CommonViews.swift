import SwiftUI
import MapKit

struct Notices: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if let error = store.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                .accessibilityIdentifier("requestError")
        }
        if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
        if store.busy { ProgressView("Saving...") }
    }
}
struct Polling: ViewModifier {
    let active: Bool
    let seconds: UInt64
    let refresh: () async -> Void
    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
                catch { return }
            }
        }
    }
}
struct PushLifecycle: ViewModifier {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var push = PushService.shared
    func body(content: Content) -> some View {
        content
            .task(id: store.session?.token) { await store.registerPush() }
            .onChange(of: push.token) { _, _ in Task { await store.registerPush() } }
            .onChange(of: push.apnsReady) { _, ready in if ready { Task { await store.registerPush() } } }
            .onChange(of: push.tapped) { _, _ in
                guard store.session != nil else { return }
                store.tab = store.kind == .parent ? 2 : 3
            }
    }
}
struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var identifier = ""
    @State private var password = ""
    @State private var setup = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Label(store.kind.title, systemImage: "bus.fill").font(.title2) }
                Section {
                    Notices()
                    TextField("Email or phone", text: $identifier)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    Button("Sign in") { Task { await store.login(identifier: identifier, password: password) } }
                        .disabled(store.busy).accessibilityIdentifier("signIn")
                }
                if store.kind == .parent {
                    Button("First time here? Set up account") { setup = true }
                }
            }
            .navigationTitle("Welcome")
            .sheet(isPresented: $setup) { RegistrationView() }
        }
    }
}
struct RegistrationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var phone = ""
    @State private var found = false
    @State private var description = ""
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        NavigationStack {
            Form {
                Notices()
                if !found {
                    TextField("Registered phone number", text: $phone).keyboardType(.phonePad)
                    Button("Find account") {
                        Task {
                            await store.run {
                                let result = try await store.registration(phone: phone)
                                description = [result.firstName, result.schoolName].compactMap { $0 }.joined(separator: " - ")
                                found = true
                            }
                        }
                    }.disabled(store.busy)
                } else {
                    Text(description)
                    SecureField("New password", text: $password).textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                    Button("Finish and sign in") {
                        Task { await store.completeRegistration(phone: phone, password: password, confirmation: confirmation) }
                    }.disabled(store.busy)
                    Button("Use another number") { found = false }
                }
            }
            .navigationTitle("Set up account")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}
struct PasswordView: View {
    @EnvironmentObject var store: AppStore
    let forced: Bool
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    var body: some View {
        Form {
            Section {
                Notices()
                if forced { Text("Choose a new password before continuing.") }
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password", text: $new).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmation).textContentType(.newPassword)
                Button("Change password") {
                    Task {
                        await store.changePassword(current: current, new: new, confirmation: confirmation)
                        if store.error == nil { current = ""; new = ""; confirmation = "" }
                    }
                }.disabled(store.busy)
            }
            if forced { Button("Sign out") { Task { await store.logout() } }.disabled(store.busy) }
        }.navigationTitle("Account security")
    }
}
struct TripSummary: View {
    let trip: Trip
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trip.route?.name ?? "Route").font(.headline)
            Text([trip.type, trip.status].compactMap { $0 }.joined(separator: " - ").replacingOccurrences(of: "_", with: " "))
            if let date = trip.scheduledDate { Text(date).font(.caption) }
            if let plate = trip.vehicle?.plateNumber { Text(plate) }
            if let duration = trip.durationMinutes { Text("Duration: \(duration) minutes") }
        }
    }
}
struct DestinationMap: View {
    let coordinate: Coordinate
    let title: String
    var body: some View {
        Map(initialPosition: .region(.init(center: coordinate.mapCoordinate,
            span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008)))) {
            Marker(title, coordinate: coordinate.mapCoordinate)
        }.frame(height: 220).id("\(coordinate.lat):\(coordinate.lng)")
        Button("Navigate") {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.mapCoordinate))
            item.name = title
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        }
    }
}
struct PhoneLink: View {
    let phone: String
    let title: String
    var body: some View {
        if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
            Link(title, destination: url)
        }
    }
}
struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let active: Bool
    @State private var text = ""
    @State private var absence = false
    @State private var clear = false
    var body: some View {
        NavigationStack {
            List {
                Section { Notices() }
                if let partner = store.partner {
                    Section {
                        if store.messages.isEmpty { Text("No messages in this conversation.") }
                        ForEach(store.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.senderId == store.session?.user.id ? "You" : partner.partnerName).font(.caption)
                                Text(message.content)
                                if let date = message.createdAt { Text(date).font(.caption2).foregroundStyle(.secondary) }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { Task { await store.deleteMessage(message.id) } } }
                        }
                    }
                    Section {
                        TextField("Message", text: $text, axis: .vertical)
                        Button("Send") {
                            Task { if await store.send(text) { text = "" } }
                        }.disabled(store.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let phone = partner.partnerPhone { PhoneLink(phone: phone, title: "Call \(partner.partnerName)") }
                } else {
                    if !store.loaded.contains("chat") { ProgressView("Loading conversations...") }
                    Section("Conversations (\(store.unread) unread)") {
                        if store.conversations.isEmpty && store.loaded.contains("chat") { Text("No conversations yet.") }
                        ForEach(store.conversations) { conversation in
                            Button {
                                store.openChat(conversation)
                                Task { await store.refreshChat() }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(conversation.partnerName)
                                    Text(conversation.lastMessage ?? "").font(.caption).foregroundStyle(.secondary)
                                    if let unread = conversation.unreadCount, unread > 0 { Text("\(unread) unread").font(.caption) }
                                }
                            }
                        }
                    }
                    Section(store.kind == .parent ? "Drivers" : "Route parents") {
                        ForEach(Array(store.contacts.enumerated()), id: \.offset) { _, person in
                            if let id = person.id {
                                Button(person.fullName) {
                                    store.openChat(Conversation(partnerId: id, partnerName: person.fullName,
                                        partnerRole: person.role, partnerPhone: person.phone, lastMessage: nil, unreadCount: nil))
                                    Task { await store.refreshChat() }
                                }
                            }
                        }
                    }
                    if store.kind == .parent { Button("Report absence") { absence = true } }
                }
            }
            .navigationTitle(store.partner?.partnerName ?? "Messages")
            .toolbar {
                if store.partner != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Conversations") { store.closeChat(); Task { await store.refreshChat() } }
                    }
                    ToolbarItem(placement: .topBarTrailing) { Button("Clear", role: .destructive) { clear = true } }
                }
            }
            .refreshable { await store.refreshChat() }
            .confirmationDialog("Clear this conversation?", isPresented: $clear) {
                Button("Clear", role: .destructive) { Task { await store.deleteMessage(nil) } }
            }
            .sheet(isPresented: $absence) { AbsenceView() }
            .modifier(Polling(active: active, seconds: 10, refresh: store.refreshChat))
        }
    }
}
struct AbsenceView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var selected: Set<Int> = []
    @State private var date = Date()
    @State private var reason = ""
    var body: some View {
        NavigationStack {
            Form {
                Notices()
                Section("Children") {
                    ForEach(store.students) { child in
                        Toggle(child.fullName, isOn: Binding(get: { selected.contains(child.id) }, set: { value in
                            if value { selected.insert(child.id) } else { selected.remove(child.id) }
                        }))
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Reason", text: $reason, axis: .vertical)
                Button("Report absence") { Task { await store.absence(ids: selected, reason: reason, date: date) } }
                    .disabled(store.busy || selected.isEmpty)
            }
            .navigationTitle("Report absence")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var push = PushService.shared
    @State private var confirmLogout = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Notices() }
                if let user = store.session?.user {
                    Section("Account") {
                        Text(user.fullName).font(.headline)
                        Text(user.email ?? "Email not set")
                        Text(user.phone ?? "Phone not set")
                        ForEach(user.parentSchools ?? user.school.map { [$0] } ?? []) { school in Text(school.name) }
                    }
                    if store.kind == .parent {
                        Section("Children") {
                            ForEach(store.students) { child in
                                VStack(alignment: .leading) {
                                    Text(child.fullName)
                                    Text([child.grade, child.school?.name].compactMap { $0 }.joined(separator: " - ")).font(.caption)
                                    ForEach(child.routes ?? []) { route in Text(route.name ?? "Route").font(.caption) }
                                }
                            }
                        }
                        Section("Pickup") {
                            Text(user.pickupAddress ?? "Pickup not set")
                            NavigationLink("Edit pickup location") { PickupEditor(user: user) }
                        }
                    }
                }
                Section("Security") { NavigationLink("Change password") { PasswordView(forced: false) } }
                Section("Notifications") {
                    if let notice = push.notice { Text(notice).font(.caption) }
                    Button("Enable / retry notifications") { Task { await store.registerPush() } }
                    if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open permission settings", destination: url) }
                }
                Section("iOS version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Version unavailable")
                    if let url = Configuration.updateURL { Link("Open iOS release page", destination: url) }
                    else { Text("An iOS App Store / TestFlight release link has not been configured. Android downloads are not iOS updates.").font(.caption) }
                }
                Button("Sign out", role: .destructive) { confirmLogout = true }.disabled(store.busy)
            }
            .navigationTitle("Profile")
            .task { await store.refreshProfile() }
            .refreshable { await store.refreshProfile() }
            .confirmationDialog("Sign out?", isPresented: $confirmLogout) {
                Button("Sign out", role: .destructive) { Task { await store.logout() } }
            }
        }
    }
}
struct PickupEditor: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var location: LocationService
    @State private var address: String
    @State private var latitude: String
    @State private var longitude: String
    init(user: User) {
        _location = StateObject(wrappedValue: LocationService(driver: false))
        _address = State(initialValue: user.pickupAddress ?? "")
        _latitude = State(initialValue: user.pickupLat.map { String($0) } ?? "")
        _longitude = State(initialValue: user.pickupLng.map { String($0) } ?? "")
    }
    var body: some View {
        Form {
            Notices()
            TextField("Pickup address", text: $address)
            MapReader { proxy in
                Map {
                    if let point = Coordinate.valid(Double(latitude), Double(longitude)) {
                        Marker("Pickup", coordinate: point.mapCoordinate)
                    }
                }
                .frame(height: 280)
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        latitude = String(coordinate.latitude); longitude = String(coordinate.longitude)
                    }
                }
            }
            Text("Tap the map to choose a pickup point. Active trip destinations do not change.")
            TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
            TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
            Button("Use current location") { location.currentPosition() }
            if let notice = location.notice { Text(notice).font(.caption) }
            Button("Save pickup") { Task { await store.updatePickup(address: address, latitude: latitude, longitude: longitude) } }
                .disabled(store.busy)
        }
        .navigationTitle("Pickup location")
        .onChange(of: location.position) { _, point in
            if let point { latitude = String(point.lat); longitude = String(point.lng) }
        }
        .onDisappear { location.stop() }
    }
}
