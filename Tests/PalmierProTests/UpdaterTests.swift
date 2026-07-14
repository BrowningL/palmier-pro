import Testing
@testable import PalmierPro

@Suite("Updater configuration")
@MainActor
struct UpdaterTests {
    @Test("official app bundle enables a configured feed")
    func officialBundleEnablesUpdates() {
        #expect(Updater.shouldEnableUpdates(
            bundlePathExtension: "app",
            infoDictionary: ["SUFeedURL": "https://example.com/appcast.xml"]
        ))
    }

    @Test("custom fork never consumes the official feed")
    func customForkDisablesUpdates() {
        #expect(!Updater.shouldEnableUpdates(
            bundlePathExtension: "app",
            infoDictionary: [
                "PalmierForkBuild": true,
                "SUFeedURL": "https://example.com/appcast.xml",
            ]
        ))
    }

    @Test("unbundled and unconfigured builds do not start Sparkle")
    func incompleteConfigurationDisablesUpdates() {
        #expect(!Updater.shouldEnableUpdates(
            bundlePathExtension: "",
            infoDictionary: ["SUFeedURL": "https://example.com/appcast.xml"]
        ))
        #expect(!Updater.shouldEnableUpdates(
            bundlePathExtension: "app",
            infoDictionary: [:]
        ))
    }
}
