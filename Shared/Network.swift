import Foundation
import Security

enum AppKind: String {
    case driver, parent
    var title: String { self == .driver ? "Carribu Driver" : "Carribu Parent" }
    func accepts(_ role: String) -> Bool {
        self == .parent ? role == "parent" : ["driver", "coordinator", "admin", "school_admin"].contains(role)
    }
}
struct AppFailure: LocalizedError {
    let message: String
    let status: Int?
    init(_ message: String, status: Int? = nil) { self.message = message; self.status = status }
    var errorDescription: String? { message }
}
func required<T>(_ value: T?, _ field: String) throws -> T {
    guard let value else { throw AppFailure("The server response is missing \(field). Please retry or contact support.") }
    return value
}
enum Configuration {
    static var baseURL: String { Bundle.main.object(forInfoDictionaryKey: "CarribuAPIBaseURL") as? String ?? "" }
    static var updateURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "CarribuUpdateURL") as? String,
              let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }
    static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), let host = url.host, url.scheme == "https",
              !host.hasSuffix(".invalid"), url.path.hasSuffix("/api/"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AppFailure("Configure a valid HTTPS API base URL ending in /api/ in Local.xcconfig before signing in.")
        }
        return url
    }
}
final class KeychainSession {
    private let service = Bundle.main.bundleIdentifier ?? "Carribu"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "session"]
    }
    func load() throws -> Session? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppFailure("Secure session could not be read (Keychain \(status)).")
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }
    func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(request as CFDictionary, nil)
            guard result == errSecSuccess else { throw AppFailure("Secure session could not be saved (Keychain \(result)).") }
        } else if status != errSecSuccess {
            throw AppFailure("Secure session could not be updated (Keychain \(status)).")
        }
    }
    func clear() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw AppFailure("Secure session could not be removed (Keychain \(result)).")
        }
    }
}
@MainActor
final class API {
    var token: String?
    var unauthorized: ((String) -> Void)?
    private let baseURL: String
    private let transport: URLSession
    init(baseURL: String = Configuration.baseURL, transport: URLSession = .shared) {
        self.baseURL = baseURL
        self.transport = transport
    }
    func request(_ path: String, method: String = "GET", body: [String: JSONValue]? = nil,
                 query: [URLQueryItem] = []) async throws -> Payload {
        let base = try Configuration.validatedURL(baseURL)
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AppFailure("The API address could not be constructed.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AppFailure("The API address is invalid.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let issuedToken = token
        if let issuedToken { request.setValue("Bearer \(issuedToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AppFailure("The server returned an invalid response.") }
        if response.statusCode == 401, let issuedToken, issuedToken == token { unauthorized?(issuedToken) }
        guard (200...299).contains(response.statusCode) else {
            struct ServerError: Decodable { let error: String?; let message: String? }
            let failure = try? JSONDecoder().decode(ServerError.self, from: data)
            throw AppFailure(failure?.error ?? failure?.message ?? "Request failed (HTTP \(response.statusCode)).", status: response.statusCode)
        }
        do {
            if path == "driver/active-trip" {
                struct ActiveResponse: Decodable {
                    let activeTrip: Trip?
                    enum CodingKeys: String, CodingKey { case activeTrip }
                    init(from decoder: Decoder) throws {
                        let values = try decoder.container(keyedBy: CodingKeys.self)
                        guard values.contains(.activeTrip) else {
                            throw AppFailure("The server response is missing activeTrip.")
                        }
                        activeTrip = try values.decodeIfPresent(Trip.self, forKey: .activeTrip)
                    }
                }
                _ = try JSONDecoder().decode(ActiveResponse.self, from: data)
            }
            return try JSONDecoder().decode(Payload.self, from: data)
        }
        catch { throw AppFailure("The server response did not match the expected API contract: \(error.localizedDescription)") }
    }
}
