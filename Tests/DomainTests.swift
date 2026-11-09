import XCTest
#if DRIVER_TESTS
@testable import CarribuDriver
#else
@testable import CarribuParent
#endif

final class DomainTests: XCTestCase {
    func testFreshnessExactBoundaries() {
        XCTAssertTrue(TripRules.freshAge(-30))
        XCTAssertTrue(TripRules.freshAge(120))
        XCTAssertFalse(TripRules.freshAge(-30.001))
        XCTAssertFalse(TripRules.freshAge(120.001))
        XCTAssertFalse(TripRules.freshAge(.nan))
    }
    func testCoordinatesAndZero() {
        XCTAssertNotNil(Coordinate.valid(0, 0))
        XCTAssertNil(Coordinate.valid(91, 1))
        XCTAssertNil(Coordinate.valid(0, .infinity))
        XCTAssertNil(Coordinate.valid(nil, 0))
    }
    func testCanonicalActionPhaseAndStableKeys() {
        XCTAssertEqual(TripRules.phase(action: "arrived", status: "on_bus"), "dropoff")
        XCTAssertEqual(TripRules.phase(action: "check_in", status: "pending"), "pickup")
        XCTAssertEqual(TripRules.key(trip: 1, student: 2, phase: "dropoff", action: "arrived"), "1:2:dropoff:arrived")
        XCTAssertTrue(TripRules.actions(status: "on_bus", tripPhase: "school_boarding").isEmpty)
        XCTAssertEqual(TripRules.actions(status: "on_bus", tripPhase: "school_dropoff"), ["arrived", "check_out"])
    }
    func testDecimalStringsDecodeAndMissingCoordinatesRemainMissing() throws {
        let data = Data(#"{"lat":"0.00","lng":"36.8","recordedAt":"2026-11-05T08:00:00Z","isFresh":true}"#.utf8)
        let location = try JSONDecoder().decode(BusLocation.self, from: data)
        XCTAssertEqual(location.lat, 0)
        XCTAssertEqual(location.lng, 36.8)
        let absent = try JSONDecoder().decode(BusLocation.self, from: Data("{}".utf8))
        XCTAssertNil(absent.coordinate)
        XCTAssertFalse(absent.fresh())
    }
    func testPasswordAndRoles() {
        XCTAssertNotNil(TripRules.password("short", confirmation: "short", current: nil))
        XCTAssertNotNil(TripRules.password("secret1", confirmation: "secret1", current: "secret1"))
        XCTAssertTrue(AppKind.driver.accepts("coordinator"))
        XCTAssertFalse(AppKind.parent.accepts("admin"))
    }
    func testOlderGPSDoesNotReplaceNewerFixOrExposeOldETA() throws {
        func bus(_ time: String, _ lat: Double) throws -> ActiveBus {
            let json = """
            {"tripId":1,"tripType":"morning_pickup","routeName":"Test",
             "location":{"lat":\(lat),"lng":1,"source":"traccar","recordedAt":"\(time)","isFresh":true},
             "children":[{"id":2,"firstName":"Synthetic","eta":{"totalMinutes":3}}]}
            """
            return try JSONDecoder().decode(ActiveBus.self, from: Data(json.utf8))
        }
        let old = try bus("2026-11-05T08:00:00Z", 1)
        let new = try bus("2026-11-05T08:00:10Z", 2)
        let merged = TripRules.merge(old, previous: new)
        XCTAssertEqual(merged.location?.lat, 2)
        XCTAssertNil(merged.children?.first?.eta)
    }
    func testConfigurationRejectsUnconfiguredAndNonTLSURLs() {
        XCTAssertThrowsError(try Configuration.validatedURL("https://configure-me.invalid/api/"))
        XCTAssertThrowsError(try Configuration.validatedURL("http://example.test/api/"))
        XCTAssertThrowsError(try Configuration.validatedURL("https://example.test/"))
        XCTAssertNoThrow(try Configuration.validatedURL("https://example.test/api/"))
    }
}
