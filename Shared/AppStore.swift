import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    let kind: AppKind
    let api = API()
    let location: LocationService
    private let keychain = KeychainSession()
    private var generation = UUID()
    private var driverGeneration = 0
    private var busGeneration = 0
    private var tripsGeneration = 0
    private var chatGeneration = 0
    private var pushRegistration: Task<Void, Never>?
    private var pushRegistrationRequested = false
    private var signingOut = false
    @Published var session: Session?
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var tab = 0
    @Published var activeTrip: Trip?
    @Published var driverTrips: [Trip] = []
    @Published var routes: [Route] = []
    @Published var driverHistory: [Trip] = []
    @Published var buses: [ActiveBus] = []
    @Published var selectedBus: Int?
    @Published var upcoming: [Trip] = []
    @Published var history: [Trip] = []
    @Published var filters: Filters?
    @Published var schoolID: Int?
    @Published var studentID: Int?
    @Published var notifications: [ChatMessage] = []
    @Published var conversations: [Conversation] = []
    @Published var contacts: [Person] = []
    @Published var students: [Student] = []
    @Published var messages: [ChatMessage] = []
    @Published var partner: Conversation?
    @Published var unread = 0
    @Published var loaded: Set<String> = []

    init(kind: AppKind) {
        self.kind = kind
        location = LocationService(driver: kind == .driver)
        do {
            if let saved = try keychain.load() {
                if saved.baseURL != Configuration.baseURL || !kind.accepts(saved.user.role) {
                    try keychain.clear()
                } else {
                    session = saved
                    api.token = saved.token
                }
            }
        } catch { self.error = error.localizedDescription }
        location.upload = { [weak self] id, coordinate, speed, heading in
            guard let self else { throw CancellationError() }
            var body: [String: JSONValue] = ["tripId": .int(id), "lat": .double(coordinate.lat), "lng": .double(coordinate.lng)]
            if let speed { body["speed"] = .double(speed) }
            if let heading { body["heading"] = .double(heading) }
            _ = try await self.api.request("location/update", method: "POST", body: body)
        }
        api.unauthorized = { [weak self] token in
            guard let self, self.session?.token == token else { return }
            self.clearSession()
            self.error = "Your session expired. Sign in again."
        }
    }

    private func ensure(_ value: UUID) throws {
        guard generation == value else { throw CancellationError() }
        try Task.checkCancellation()
    }
    func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do { try await operation() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
    private func refresh(_ resource: String, _ operation: () async throws -> Void) async {
        let current = generation
        do {
            try await operation()
            try ensure(current)
            loaded.insert(resource)
            if !busy { error = nil }
        } catch is CancellationError {}
        catch {
            if current == generation {
                self.error = error.localizedDescription
                loaded.insert(resource)
            }
        }
    }
    private func accept(_ result: Payload, current: UUID) throws {
        try ensure(current)
        let token = try required(result.token, "token")
        let user = try required(result.user, "user")
        guard kind.accepts(user.role), !token.isEmpty else {
            throw AppFailure("This account cannot sign in to the \(kind.title) app.")
        }
        let value = Session(token: token, user: user, baseURL: Configuration.baseURL)
        try keychain.save(value)
        generation = UUID()
        session = value
        api.token = token
        tab = 0
    }
    func login(identifier: String, password: String) async {
        await run {
            guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
                throw AppFailure("Enter your email or phone and password.")
            }
            let current = generation
            let result = try await api.request("auth/login", method: "POST", body: [
                "email": .string(identifier.trimmingCharacters(in: .whitespacesAndNewlines)), "password": .string(password)
            ])
            try accept(result, current: current)
        }
    }
    func registration(phone: String) async throws -> Payload {
        guard !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure("Enter the phone number registered by your school.")
        }
        let result = try await api.request("auth/registration-status", method: "POST", body: ["phone": .string(phone.trimmingCharacters(in: .whitespacesAndNewlines))])
        guard try required(result.found, "found") else { throw AppFailure("No pending parent account was found. Contact your school.") }
        return result
    }
    func completeRegistration(phone: String, password: String, confirmation: String) async {
        await run {
            if let error = TripRules.password(password, confirmation: confirmation, current: nil) { throw AppFailure(error) }
            let current = generation
            let result = try await api.request("auth/complete-registration", method: "POST", body: [
                "phone": .string(phone.trimmingCharacters(in: .whitespacesAndNewlines)), "newPassword": .string(password)
            ])
            try accept(result, current: current)
        }
    }
    func changePassword(current: String, new: String, confirmation: String) async {
        await run {
            guard !current.isEmpty else { throw AppFailure("Enter your current password.") }
            if let error = TripRules.password(new, confirmation: confirmation, current: current) { throw AppFailure(error) }
            let version = generation
            _ = try await api.request("auth/change-password", method: "PUT", body: ["currentPassword": .string(current), "newPassword": .string(new)])
            try ensure(version)
            if var value = session {
                value.user.mustSetPassword = false
                try keychain.save(value)
                session = value
            }
            notice = "Password changed."
        }
    }
    private func clearSession() {
        location.stop()
        generation = UUID()
        api.token = nil
        session = nil
        activeTrip = nil
        driverTrips = []; routes = []; driverHistory = []
        buses = []; selectedBus = nil; upcoming = []; history = []; filters = nil
        schoolID = nil; studentID = nil; notifications = []
        conversations = []; contacts = []; students = []; messages = []; partner = nil
        unread = 0; tab = 0; loaded = []
        pushRegistrationRequested = false
        PushService.shared.clear()
        do { try keychain.clear() }
        catch { self.error = error.localizedDescription }
    }
    func logout() async {
        await run {
            signingOut = true
            defer { signingOut = false }
            await pushRegistration?.value
            var failure: String?
            do {
                _ = try await api.request("auth/push-token", method: "PUT", body: ["pushToken": .null, "provider": .string("fcm")])
            } catch { failure = "Signed out, but notification unregistration failed: \(error.localizedDescription)" }
            clearSession()
            if let failure { error = failure }
        }
    }
    func refreshDriver() async {
        driverGeneration += 1
        let version = driverGeneration
        let current = generation
        await refresh("driver") {
            let active = try await api.request("driver/active-trip")
            let scheduled = try await api.request("driver/my-trips")
            let trips = try required(scheduled.trips, "trips")
            try ensure(current)
            guard version == driverGeneration else { throw CancellationError() }
            activeTrip = active.activeTrip
            driverTrips = trips
            location.configure(active.activeTrip)
        }
    }
    func start(_ trip: Trip) async {
        await run {
            let current = generation
            _ = try await api.request("trips/\(trip.id)/acknowledge", method: "PUT")
            try ensure(current)
            driverGeneration += 1
            notice = "Trip acknowledged and started."
            await refreshDriver()
        }
    }
    func end(_ trip: Trip) async {
        await run {
            guard trip.canEnd == true else { throw AppFailure("Resolve every student as dropped off or absent before ending.") }
            let current = generation
            _ = try await api.request("trips/\(trip.id)/end", method: "PUT")
            try ensure(current)
            driverGeneration += 1
            activeTrip = nil
            location.stop()
            notice = "Trip completed."
            await refreshDriver()
        }
    }
    func action(_ action: String, student: Stop, trip: Trip) async {
        await run {
            let current = generation
            let phase = TripRules.phase(action: action, status: student.status)
            _ = try await api.request("trips/\(trip.id)/log", method: "POST", body: [
                "studentId": .int(student.studentId), "action": .string(action), "phase": .string(phase),
                "idempotencyKey": .string(TripRules.key(trip: trip.id, student: student.studentId, phase: phase, action: action))
            ])
            try ensure(current)
            driverGeneration += 1
            await refreshDriver()
        }
    }
    func refreshRoutes() async {
        let current = generation
        await refresh("routes") {
            let result = try await api.request("driver/my-routes")
            let values = try required(result.routes, "routes")
            try ensure(current)
            routes = values
        }
    }
    func refreshDriverHistory() async {
        let current = generation
        await refresh("driverHistory") {
            let result = try await api.request("driver/trip-history", query: [.init(name: "days", value: "30")])
            let values = try required(result.trips, "trips")
            try ensure(current)
            driverHistory = values
        }
    }
    func refreshBuses() async {
        busGeneration += 1
        let version = busGeneration
        let current = generation
        await refresh("buses") {
            do {
                let result = try await api.request("location/my-bus")
                let values = try required(result.activeBuses, "activeBuses")
                try ensure(current)
                guard version == busGeneration else { throw CancellationError() }
                buses = values.map { incoming in
                    TripRules.merge(incoming, previous: buses.first { old in old.tripId == incoming.tripId })
                }
                if !buses.contains(where: { $0.tripId == selectedBus }) { selectedBus = buses.first?.tripId }
            } catch {
                if current == generation && version == busGeneration {
                    buses = buses.map { bus in var value = bus; value.location?.isFresh = false; return value }
                }
                throw error
            }
        }
    }
    func refreshParentTrips() async {
        tripsGeneration += 1
        let version = tripsGeneration
        let current = generation
        var query: [URLQueryItem] = []
        if let schoolID { query.append(.init(name: "schoolId", value: String(schoolID))) }
        if let studentID { query.append(.init(name: "studentId", value: String(studentID))) }
        await refresh("parentTrips") {
            let next = try await api.request("parent/upcoming-trips", query: query + [.init(name: "days", value: "7")])
            let past = try await api.request("parent/trip-history", query: query + [.init(name: "days", value: "30")])
            let futureTrips = try required(next.trips, "trips")
            let pastTrips = try required(past.trips, "trips")
            let metadata = try required(past.filters ?? next.filters, "filters")
            try ensure(current)
            guard version == tripsGeneration else { throw CancellationError() }
            upcoming = futureTrips; history = pastTrips; filters = metadata
        }
    }
    func selectSchool(_ id: Int?) {
        schoolID = id
        if let studentID, let id, !(filters?.students?.contains { $0.id == studentID && $0.schoolId == id } ?? false) {
            self.studentID = nil
        }
    }
    func refreshAlerts() async {
        let current = generation
        await refresh("alerts") {
            let result = try await api.request("messages/notifications")
            let values = try required(result.notifications, "notifications")
            try ensure(current)
            notifications = values
        }
    }
    func removeAlert(_ id: Int?) async {
        await run {
            let current = generation
            _ = try await api.request(id.map { "messages/notifications/\($0)" } ?? "messages/notifications", method: "DELETE")
            try ensure(current)
            if let id { notifications.removeAll { $0.id == id } } else { notifications = [] }
        }
    }
    func refreshChat() async {
        chatGeneration += 1
        let version = chatGeneration
        let current = generation
        let selected = partner
        await refresh("chat") {
            if let selected {
                let result = try await api.request("messages/thread/\(selected.partnerId)")
                let values = try required(result.messages, "messages")
                try ensure(current)
                guard version == chatGeneration, partner?.id == selected.id else { throw CancellationError() }
                messages = values
            } else {
                let result = try await api.request("messages/conversations")
                let values = try required(result.conversations, "conversations")
                var people: [Person] = []
                var children: [Student] = []
                var count = 0
                if kind == .parent {
                    let drivers = try await api.request("messages/my-drivers")
                    let roster = try await api.request("students")
                    let unreadResult = try await api.request("messages/unread-count")
                    people = try required(drivers.drivers, "drivers")
                    children = try required(roster.students, "students")
                    count = try required(unreadResult.unreadCount, "unreadCount")
                } else {
                    let response = try await api.request("driver/my-routes")
                    for route in try required(response.routes, "routes") {
                        let result = try await api.request("messages/route-parents/\(route.id)")
                        for person in try required(result.parents, "parents") {
                            if !people.contains(where: { $0.id == person.id }) { people.append(person) }
                        }
                    }
                }
                try ensure(current)
                guard version == chatGeneration, partner == nil else { throw CancellationError() }
                conversations = values; contacts = people; students = children; unread = count
            }
        }
    }
    func openChat(_ value: Conversation) { chatGeneration += 1; partner = value; messages = [] }
    func closeChat() { chatGeneration += 1; partner = nil; messages = []; loaded.remove("chat") }
    func send(_ text: String) async -> Bool {
        var sent = false
        await run {
            guard let partner, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppFailure("Choose a conversation and enter a message.")
            }
            let current = generation
            _ = try await api.request("messages", method: "POST", body: ["receiverId": .int(partner.partnerId),
                "content": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)), "messageType": .string("text")])
            try ensure(current)
            sent = true
            await refreshChat()
        }
        return sent
    }
    func deleteMessage(_ id: Int?) async {
        await run {
            guard let partner else { throw AppFailure("Choose a conversation first.") }
            let current = generation
            _ = try await api.request(id.map { "messages/\($0)" } ?? "messages/thread/\(partner.id)", method: "DELETE")
            try ensure(current)
            chatGeneration += 1
            if let id { messages.removeAll { $0.id == id } } else { messages = [] }
        }
    }
    func absence(ids: Set<Int>, reason: String, date: Date) async {
        await run {
            guard !ids.isEmpty else { throw AppFailure("Select at least one child.") }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let current = generation
            let response = try await api.request("messages/absence", method: "POST", body: [
                "studentIds": .array(ids.sorted().map(JSONValue.int)), "reason": .string(reason.isEmpty ? "Not specified" : reason),
                "date": .string(formatter.string(from: date))
            ])
            try ensure(current)
            notice = response.message?.text ?? "Absence reported."
        }
    }
    func refreshProfile() async {
        guard kind == .parent else { loaded.insert("profile"); return }
        let current = generation
        await refresh("profile") {
            let result = try await api.request("auth/me")
            let roster = try await api.request("students")
            let user = try required(result.user, "user")
            let values = try required(roster.students, "students")
            try ensure(current)
            guard var value = session, kind.accepts(user.role) else { throw AppFailure("The refreshed account is not authorized.") }
            value.user = user
            try keychain.save(value)
            session = value; students = values
        }
    }
    func updatePickup(address: String, latitude: String, longitude: String) async {
        await run {
            guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let coordinate = Coordinate.valid(Double(latitude), Double(longitude)) else {
                throw AppFailure("Enter an address and choose a valid pickup coordinate.")
            }
            let current = generation
            _ = try await api.request("auth/profile", method: "PUT", body: [
                "pickupAddress": .string(address.trimmingCharacters(in: .whitespacesAndNewlines)),
                "pickupLat": .double(coordinate.lat), "pickupLng": .double(coordinate.lng)
            ])
            try ensure(current)
            await refreshProfile()
            notice = "Pickup location saved. Active trip destinations remain frozen."
        }
    }
    func registerPush() async {
        guard !signingOut, session != nil else { return }
        pushRegistrationRequested = true
        if let pushRegistration { await pushRegistration.value; return }
        let task = Task {
            repeat {
                pushRegistrationRequested = false
                await performPushRegistration()
            } while pushRegistrationRequested && !signingOut && session != nil
        }
        pushRegistration = task
        await task.value
        pushRegistration = nil
    }
    private func performPushRegistration() async {
        guard let token = session?.token else { return }
        let current = generation
        do {
            let deviceToken = try await PushService.shared.prepare()
            try ensure(current)
            guard api.token == token else { throw CancellationError() }
            _ = try await api.request("auth/push-token", method: "PUT", body: ["pushToken": .string(deviceToken), "provider": .string("fcm")])
            try ensure(current)
            PushService.shared.notice = "Notification token registered. Device delivery still depends on APNs and permissions."
        } catch is CancellationError {}
        catch {
            if current == generation { PushService.shared.notice = "Notifications unavailable: \(error.localizedDescription)" }
        }
    }
}
