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
    func testSessionReleasedOffMainIsDestroyedOnMain() throws {
        let runtime = try RimeRuntime.start(RimeFixture.compiled("fixture"))
        let destroyed = expectation(description: "destroyed")
        let ranOnMain = LockedFlag()
        RimeSession.onDestroy = { isMain in ranOnMain.set(isMain); destroyed.fulfill() }
        defer { RimeSession.onDestroy = nil }
        var session: RimeSession? = try runtime.makeSession(schema: "fixture")
        let box = SessionBox(session); session = nil
        DispatchQueue.global().async { box.release() }
        wait(for: [destroyed], timeout: 5)
        XCTAssertTrue(ranOnMain.value)
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

    func testStateReadsAtMostCandidateLimit() throws {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "fixture")
        session.candidateLimit = 1
        _ = session.processKey(Int32(UInt8(ascii: "a"))); _ = session.processKey(Int32(UInt8(ascii: "b")))
        XCTAssertEqual(session.state.candidates, ["明"])
    }

    func testPreeditUsesSchemaFormat() throws {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "zhuyin")
        for key in "a83" { _ = session.processKey(Int32(key.asciiValue!)) }
        XCTAssertEqual(session.preedit, "ㄇㄚˇ")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
private final class SessionBox: @unchecked Sendable {
    private var session: RimeSession?
    init(_ s: RimeSession?) { session = s }
    func release() { session = nil }
}
