import Foundation

@propertyWrapper
struct FlexibleDouble: Codable {
    var wrappedValue: Double?
    init(wrappedValue: Double? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { wrappedValue = nil }
        else if let number = try? value.decode(Double.self) { wrappedValue = number }
        else {
            let text = try value.decode(String.self)
            guard let number = Double(text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid numeric coordinate")
            }
            wrappedValue = number
        }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: FlexibleDouble.Type, forKey key: Key) throws -> FlexibleDouble {
        try decodeIfPresent(type, forKey: key) ?? FlexibleDouble()
    }
}

struct School: Codable, Identifiable { let id: Int; let name: String }
struct Person: Codable, Identifiable {
    let id: Int?
    let firstName: String?
    let lastName: String?
    let name: String?
    let phone: String?
    let email: String?
    let role: String?
    var fullName: String {
        name ?? [firstName, lastName].compactMap { $0 }.joined(separator: " ")
    }
}
struct User: Codable, Identifiable {
    let id: Int
    let firstName: String?
    let lastName: String?
    let email: String?
    let phone: String?
    let role: String
    var mustSetPassword: Bool?
    let school: School?
    let parentSchools: [School]?
    let pickupAddress: String?
    @FlexibleDouble var pickupLat: Double?
    @FlexibleDouble var pickupLng: Double?
    var fullName: String { [firstName, lastName].compactMap { $0 }.joined(separator: " ") }
}
struct Session: Codable { let token: String; var user: User; let baseURL: String }
struct Vehicle: Codable {
    let id: Int?
    let plateNumber: String?
    let trackerUniqueId: String?
    let capacity: Int?
}
struct Student: Codable, Identifiable {
    let id: Int
    let schoolId: Int?
    let firstName: String?
    let lastName: String?
    let grade: String?
    let school: School?
    let parent: Person?
    let routes: [Route]?
    var fullName: String { [firstName, lastName].compactMap { $0 }.joined(separator: " ") }
}
struct Route: Codable, Identifiable {
    let id: Int
    let name: String?
    let type: String?
    let schoolId: Int?
    let vehicle: Vehicle?
    let students: [Student]?
}
struct Stop: Codable, Identifiable {
    let studentId: Int
    let stopNumber: Int
    let studentName: String
    let status: String
    let phase: String?
    let parentName: String?
    let parentPhone: String?
    let pickupAddress: String?
    let address: String?
    @FlexibleDouble var lat: Double?
    @FlexibleDouble var lng: Double?
    var id: Int { studentId }
    var coordinate: Coordinate? { Coordinate.valid(lat, lng) }
}
struct TripStats: Codable {
    let total: Int?
    let onBus: Int?
    let droppedOff: Int?
    let absent: Int?
}
struct TripChild: Codable, Identifiable {
    let studentId: Int
    let studentName: String
    let status: String?
    let grade: String?
    var id: Int { studentId }
}
struct Trip: Codable, Identifiable {
    let id: Int
    let type: String?
    let status: String?
    let scheduledDate: String?
    let scheduledTime: String?
    let startedAt: String?
    let endedAt: String?
    let durationMinutes: Int?
    let route: Route?
    let school: School?
    let vehicle: Vehicle?
    let driver: Person?
    let pickupList: [Stop]?
    let children: [TripChild]?
    let stats: TripStats?
    let phase: String?
    let locationSource: String?
    let currentStop: Stop?
    let nextStop: Stop?
    let canEnd: Bool?
    var usesTraccar: Bool {
        locationSource == "traccar" || !(vehicle?.trackerUniqueId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
struct ETA: Codable {
    let totalMinutes: Int?
    @FlexibleDouble var distanceKm: Double?
    let alreadyPickedUp: Bool?
}
struct BusChild: Codable, Identifiable {
    let id: Int
    let firstName: String
    let lastName: String?
    let status: String?
    var eta: ETA?
}
struct BusLocation: Codable {
    @FlexibleDouble var lat: Double?
    @FlexibleDouble var lng: Double?
    let recordedAt: String?
    let source: String?
    var isFresh: Bool?
    var coordinate: Coordinate? { Coordinate.valid(lat, lng) }
    func fresh(now: Date = Date()) -> Bool {
        guard isFresh == true, coordinate != nil, let date = TripRules.timestamp(recordedAt) else { return false }
        return TripRules.freshAge(now.timeIntervalSince(date))
    }
}
struct PendingStop: Codable, Identifiable {
    let stopOrder: Int
    let studentId: Int?
    let firstName: String?
    let isMyChild: Bool?
    @FlexibleDouble var lat: Double?
    @FlexibleDouble var lng: Double?
    var id: Int { stopOrder }
    var coordinate: Coordinate? { Coordinate.valid(lat, lng) }
}
struct ActiveBus: Codable, Identifiable {
    let tripId: Int
    let tripType: String
    let routeName: String
    let routeSchool: String?
    let driver: Person?
    let vehicle: Vehicle?
    let phase: String?
    var location: BusLocation?
    var children: [BusChild]?
    let pendingStops: [PendingStop]?
    var id: Int { tripId }
    func showETA(now: Date = Date()) -> Bool {
        location?.fresh(now: now) == true && !["boarding", "school_boarding"].contains(phase ?? "")
    }
}
struct Filters: Codable { let schools: [School]?; let students: [Student]? }
struct Conversation: Codable, Identifiable {
    let partnerId: Int
    let partnerName: String
    let partnerRole: String?
    let partnerPhone: String?
    let lastMessage: String?
    let unreadCount: Int?
    var id: Int { partnerId }
}
struct ChatMessage: Codable, Identifiable {
    let id: Int
    let senderId: Int?
    let receiverId: Int?
    let content: String
    let messageType: String?
    let createdAt: String?
}
enum Notice: Decodable {
    case text(String), chat(ChatMessage)
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) }
        else { self = .chat(try container.decode(ChatMessage.self)) }
    }
    var text: String? { if case let .text(value) = self { return value }; return nil }
}
struct Payload: Decodable {
    let token: String?
    let user: User?
    let found: Bool?
    let firstName: String?
    let schoolName: String?
    let activeTrip: Trip?
    let routes: [Route]?
    let trips: [Trip]?
    let filters: Filters?
    let activeBuses: [ActiveBus]?
    let students: [Student]?
    let conversations: [Conversation]?
    let messages: [ChatMessage]?
    let notifications: [ChatMessage]?
    let drivers: [Person]?
    let parents: [Person]?
    let unreadCount: Int?
    let message: Notice?
}
enum JSONValue: Encodable {
    case string(String), int(Int), double(Double), null, array([JSONValue])
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(text): try value.encode(text)
        case let .int(number): try value.encode(number)
        case let .double(number): try value.encode(number)
        case .null: try value.encodeNil()
        case let .array(items): try value.encode(items)
        }
    }
}
struct Coordinate: Equatable {
    let lat: Double
    let lng: Double
    static func valid(_ lat: Double?, _ lng: Double?) -> Coordinate? {
        guard let lat, let lng, lat.isFinite, lng.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lng) else { return nil }
        return Coordinate(lat: lat, lng: lng)
    }
}
enum TripRules {
    static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }
    static func freshAge(_ seconds: Double) -> Bool { seconds >= -30 && seconds <= 120 }
    static func phase(action: String, status: String) -> String {
        action == "check_out" || (action == "arrived" && ["on_bus", "arrived_dropoff"].contains(status)) ? "dropoff" : "pickup"
    }
    static func key(trip: Int, student: Int, phase: String, action: String) -> String {
        "\(trip):\(student):\(phase):\(action)"
    }
    static func actions(status: String, tripPhase: String?) -> [String] {
        switch status {
        case "pending": return ["arrived", "check_in", "absent"]
        case "arrived_pickup": return ["check_in", "absent"]
        case "on_bus": return ["dropoff", "school_dropoff"].contains(tripPhase ?? "") ? ["arrived", "check_out"] : []
        case "arrived_dropoff": return ["check_out"]
        default: return []
        }
    }
    static func password(_ password: String, confirmation: String, current: String?) -> String? {
        if password.count < 6 { return "New password must be at least 6 characters." }
        if password != confirmation { return "New passwords do not match." }
        if let current, password == current { return "New password must differ from the current password." }
        return nil
    }
    static func merge(_ incoming: ActiveBus, previous: ActiveBus?) -> ActiveBus {
        guard let previous, previous.tripId == incoming.tripId,
              previous.location?.source == incoming.location?.source,
              let oldTime = timestamp(previous.location?.recordedAt),
              let newTime = timestamp(incoming.location?.recordedAt), oldTime > newTime else { return incoming }
        var result = incoming
        result.location = previous.location
        result.location?.isFresh = incoming.location?.isFresh == true
        result.children = incoming.children?.map { child in var value = child; value.eta = nil; return value }
        return result
    }
}
