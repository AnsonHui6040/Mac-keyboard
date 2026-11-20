import XCTest
@testable import RimeEngine

final class RimeRuntimeTests: XCTestCase {
    func testStartsFromPrebuiltDataWithoutDeploying() throws {
        let paths = try RimeFixture.compiled("fixture")
        let session = try RimeRuntime.start(paths).makeSession(schema: "fixture")
        XCTAssertTrue(session.processKey(Int32(UInt8(ascii: "a"))))
        XCTAssertTrue(session.processKey(Int32(UInt8(ascii: "b"))))
        XCTAssertEqual(session.state, RimeState(input: "ab", candidates: ["明", "盟"]))
    }
    func testSecondStartWithSamePathsReusesRuntime() throws {
        let paths = try RimeFixture.compiled("fixture")
        XCTAssertTrue(try RimeRuntime.start(paths) === RimeRuntime.start(paths))
    }
    func testStartWithOtherPathsThrows() throws {
        let paths = try RimeFixture.compiled("fixture")
        _ = try RimeRuntime.start(paths)
        var other = paths; other.userData = paths.userData.appending(path: "other")
        XCTAssertThrowsError(try RimeRuntime.start(other)) { XCTAssertEqual($0 as? RimeError, .alreadyStartedWithOtherPaths) }
    }
    func testUnknownSchemaThrows() throws {
        let runtime = try RimeRuntime.start(RimeFixture.compiled("fixture"))
        XCTAssertThrowsError(try runtime.makeSession(schema: "missing")) { XCTAssertEqual($0 as? RimeError, .schemaUnavailable("missing")) }
    }
    func testSelectCandidateCommitsIt() throws {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "fixture")
        _ = session.processKey(Int32(UInt8(ascii: "a"))); _ = session.processKey(Int32(UInt8(ascii: "b")))
        XCTAssertTrue(session.selectCandidate(1))
        XCTAssertEqual(session.takeCommit(), "盟")
        XCTAssertEqual(session.state, RimeState(input: "", candidates: []))
    }
    func testHealthCheckFailsWhenDictionaryIsMissing() throws {
        let runtime = try RimeRuntime.start(RimeFixture.compiled("fixture"))
        XCTAssertTrue(try runtime.makeSession(schema: "fixture").isHealthy(probeKey: "a"))
        let broken = try? runtime.makeSession(schema: "broken")
        XCTAssertFalse(broken?.isHealthy(probeKey: "a") ?? false)
    }
    func testTypingDoesNotCompileIntoStaging() throws {
        let paths = try RimeFixture.compiled("fixture")
        let session = try RimeRuntime.start(paths).makeSession(schema: "fixture")
        for key in "ablab" { _ = session.processKey(Int32(key.asciiValue!)) }
        let staging = paths.userData.appending(path: "build")
        let bins = (try? FileManager.default.contentsOfDirectory(atPath: staging.path))?.filter { $0.hasSuffix(".bin") } ?? []
        XCTAssertEqual(bins, [])
    }
}
