import XCTest
@testable import RemoteKeyboardCore

final class OnceLoaderTests: XCTestCase {
    func testConcurrentCallersShareOneLoad() async {
        let count = Counter()
        let loader = OnceLoader { await count.increment(); try? await Task.sleep(for: .milliseconds(50)); return 7 }
        async let a = loader.value(); async let b = loader.value(); async let c = loader.value()
        let values = await [a, b, c]
        XCTAssertEqual(values, [7, 7, 7])
        let loads = await count.value
        XCTAssertEqual(loads, 1)
    }
    func testResetLoadsAgain() async {
        let count = Counter()
        let loader = OnceLoader { await count.increment(); return 1 }
        _ = await loader.value(); await loader.reset(); _ = await loader.value()
        let loads = await count.value
        XCTAssertEqual(loads, 2)
    }
}
private actor Counter { var value = 0; func increment() { value += 1 } }
