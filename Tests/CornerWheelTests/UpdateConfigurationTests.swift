import XCTest
@testable import CornerWheel

final class UpdateConfigurationTests: XCTestCase {
    private var validInfo: [String: Any] {
        ["SUFeedURL": "https://updates.cornerwheel.test/appcast.xml",
         "SUPublicEDKey": Data((1...32).map(UInt8.init)).base64EncodedString()]
    }

    func testAcceptsHTTPSFeedAndEd25519PublicKey() throws {
        let configuration = try XCTUnwrap(UpdateConfiguration(infoDictionary: validInfo))
        XCTAssertEqual(configuration.feedURL.absoluteString, "https://updates.cornerwheel.test/appcast.xml")
    }

    func testUnconfiguredBuildCannotStartUpdater() {
        XCTAssertNil(UpdateConfiguration(infoDictionary: [:]))
        XCTAssertNil(UpdateConfiguration(infoDictionary: ["SUFeedURL": "", "SUPublicEDKey": ""]))
        XCTAssertNil(UpdateConfiguration(infoDictionary: ["SUFeedURL": "$(CORNERWHEEL_UPDATE_FEED_URL)",
                                                         "SUPublicEDKey": "$(CORNERWHEEL_UPDATE_PUBLIC_KEY)"]))
    }

    func testRejectsInsecureAndCredentialBearingFeeds() {
        for feed in ["http://updates.cornerwheel.test/appcast.xml", "file:///tmp/appcast.xml",
                     "https:///appcast.xml", "https://user:secret@updates.cornerwheel.test/appcast.xml",
                     "https://updates.cornerwheel.test/appcast.xml#fragment"] {
            var info = validInfo
            info["SUFeedURL"] = feed
            XCTAssertNil(UpdateConfiguration(infoDictionary: info), feed)
        }
    }

    func testRejectsMissingMalformedOrWrongLengthKey() {
        for key in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString(),
                    Data(repeating: 1, count: 33).base64EncodedString(),
                    Data(repeating: 0, count: 32).base64EncodedString()] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            XCTAssertNil(UpdateConfiguration(infoDictionary: info))
        }
    }

    @MainActor
    func testMissingConfigurationLeavesControlsDisabled() {
        let updates = AppUpdateController(infoDictionary: [:])
        updates.start()
        updates.start()
        updates.checkForUpdates()
        updates.setAutomaticallyChecksForUpdates(true)
        updates.setAutomaticallyDownloadsUpdates(true)
        XCTAssertFalse(updates.isAvailable)
        XCTAssertFalse(updates.canCheckForUpdates)
        XCTAssertFalse(updates.automaticallyChecksForUpdates)
        XCTAssertFalse(updates.automaticallyDownloadsUpdates)
        XCTAssertNil(updates.pendingUpdateVersion)
    }
}
