import XCTest
#if DRIVER_TESTS
@testable import CarribuDriver
#else
@testable import CarribuParent
#endif

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else {
                throw AppFailure("Missing test transport configuration.")
            }
            let (status, data) = try handler(request)
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw AppFailure("Invalid synthetic HTTP response.")
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class NetworkTests: XCTestCase {
    @MainActor private func client() -> API {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return API(baseURL: "https://example.test/api/", transport: URLSession(configuration: configuration))
    }
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }
    @MainActor func testAuthorizationAndAPIPath() async throws {
        let api = client()
        api.token = "synthetic-test-token"
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/driver/active-trip")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-token")
            return (200, Data(#"{"activeTrip":null}"#.utf8))
        }
        let result = try await api.request("driver/active-trip")
        XCTAssertNil(result.activeTrip)
    }
    @MainActor func testMissingActiveTripDoesNotLookLikeNoActiveTrip() async {
        let api = client()
        StubProtocol.handler = { _ in (200, Data("{}".utf8)) }
        do { _ = try await api.request("driver/active-trip"); XCTFail("Missing contract must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("activeTrip")) }
    }
    @MainActor func testExpiredSessionInvokesLogoutAndReportsFailure() async {
        let api = client()
        api.token = "synthetic-test-token"
        var expired = false
        api.unauthorized = { _ in expired = true }
        StubProtocol.handler = { _ in (401, Data(#"{"error":"Expired session"}"#.utf8)) }
        do { _ = try await api.request("auth/me"); XCTFail("Expired request must fail") }
        catch { XCTAssertEqual((error as? AppFailure)?.status, 401) }
        XCTAssertTrue(expired)
    }
    @MainActor func testConflictIsNotSuccessfulRetry() async {
        let api = client()
        StubProtocol.handler = { _ in (409, Data(#"{"error":"Conflicting action"}"#.utf8)) }
        do { _ = try await api.request("trips/1/log", method: "POST"); XCTFail("Conflict must fail") }
        catch { XCTAssertEqual((error as? AppFailure)?.status, 409) }
    }
}
