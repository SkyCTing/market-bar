import XCTest
@testable import MarketBar

final class AboutMarketBarTests: XCTestCase {
    func testVersionComesFromBundleMetadata() {
        XCTAssertEqual(AboutMarketBar.versionText(info: [
            "CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "2.3.4",
        ]), "版本：2.3.4")
    }

    func testSeparateBuildNumberIsShown() {
        XCTAssertEqual(AboutMarketBar.versionText(info: [
            "CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "27",
        ]), "版本：2.3.4\n构建：27")
    }

    func testUnpackagedBuildIsExplicitlyLabeled() {
        XCTAssertEqual(AboutMarketBar.versionText(info: [:]), "开发版本（未打包）")
        XCTAssertEqual(AboutMarketBar.versionText(info: ["CFBundleShortVersionString": ""]), "开发版本（未打包）")
    }
}
