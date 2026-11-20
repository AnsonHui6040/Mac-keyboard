#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

final class RimeMeasureLineTests: XCTestCase {
    func testTextFormat() {
        let line = RimeMeasureLine(engine: .rime, keys: 200, p50Us: 85, p95Us: 310, footprintPeakMB: 41.26,
                                   availableMinMB: 135.5, stagingBins: 0, appGroupRead: true)
        XCTAssertEqual(line.text, "RKMEAS RIME engine=rime keys=200 p50_us=85 p95_us=310 footprint_peak_mb=41.3 available_min_mb=135.5 limit_mb=176.8 staging_bins=0 appgroup_read=1")
    }
}
#endif
