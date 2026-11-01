import Foundation
import Testing
@testable import CoolDownloadCore

@Suite("v1.11.2 settings compatibility")
struct Upstream112SettingsTests {
    @Test("empty and legacy JSON hide the location column and block submission during preview", arguments: [
        "{}",
        #"{"theme":"dark","threadCount":4,"speedLimit":8192,"apiAuthKey":"fixture-legacy-key"}"#
    ])
    func legacyJSONDefaults(json: String) throws {
        let settings = try JSONDecoder().decode(AppSettingsModel.self, from: Data(json.utf8))
        #expect(!settings.showDownloadLocation)
        #expect(settings.blockAddWhenLoading)
        if json != "{}" {
            #expect(settings.theme == "dark")
            #expect(settings.threadCount == 4)
            #expect(settings.speedLimit == 8192)
            #expect(settings.apiAuthKey == "fixture-legacy-key")
        }
    }

    @Test("both new settings preserve explicit true and false values in JSON", arguments: [false, true], [false, true])
    func jsonRoundTrip(showLocation: Bool, blockLoading: Bool) throws {
        var settings = AppSettingsModel.defaults()
        settings.showDownloadLocation = showLocation
        settings.blockAddWhenLoading = blockLoading
        settings.apiAuthKey = "fixture-json-key"
        let data = try JSONEncoder().encode(settings)
        let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(encoded["showDownloadLocation"] as? Bool == showLocation)
        #expect(encoded["blockAddWhenLoading"] as? Bool == blockLoading)
        #expect(try JSONDecoder().decode(AppSettingsModel.self, from: data) == settings)
    }

    @Test("fresh and existing UserDefaults use compatible defaults for missing new keys", arguments: [false, true])
    func userDefaultsFallback(legacy: Bool) async throws {
        let root = temporaryRoot()
        let store = try SettingsStore(dataRoot: root)
        let defaults = store.defaults.defaults
        if legacy {
            defaults.set(1, forKey: "storage.schemaVersion")
            defaults.set("fixture-userdefaults-key", forKey: "apiAuthKey")
            defaults.set(false, forKey: "speedLimiterEnabled")
            defaults.set("dark", forKey: "theme")
            defaults.set(4, forKey: "threadCount")
        }
        #expect(defaults.object(forKey: "showDownloadLocation") == nil)
        #expect(defaults.object(forKey: "blockAddWhenLoading") == nil)
        let settings = try await store.load()
        #expect(!settings.showDownloadLocation)
        #expect(settings.blockAddWhenLoading)
        let reopened = try await SettingsStore(dataRoot: root).load()
        #expect(!reopened.showDownloadLocation)
        #expect(reopened.blockAddWhenLoading)
        if legacy {
            #expect(reopened.theme == "dark" && reopened.threadCount == 4)
            #expect(reopened.apiAuthKey == "fixture-userdefaults-key")
        } else {
            #expect(reopened.apiAuthKey == settings.apiAuthKey)
        }
    }

    @Test("saving settings persists both new fields across store recreation", arguments: [false, true], [false, true])
    func userDefaultsRoundTrip(showLocation: Bool, blockLoading: Bool) async throws {
        let root = temporaryRoot()
        let store = try SettingsStore(dataRoot: root)
        var settings = try await store.load()
        settings.showDownloadLocation = showLocation
        settings.blockAddWhenLoading = blockLoading
        settings.theme = "dark"
        settings.apiAuthKey = "fixture-roundtrip-key"
        _ = try await store.save(settings)
        let reopened = try await SettingsStore(dataRoot: root).load()
        #expect(reopened == settings)
        #expect(store.defaults.defaults.object(forKey: "showDownloadLocation") as? Bool == showLocation)
        #expect(store.defaults.defaults.object(forKey: "blockAddWhenLoading") as? Bool == blockLoading)
    }

    @Test("location toggles write only their key and preserve newer preview, authentication and other values")
    func targetedLocationSave() async throws {
        let root = temporaryRoot()
        let store = try SettingsStore(dataRoot: root)
        var settings = try await store.load()
        settings.blockAddWhenLoading = false
        settings.apiAuthKey = "fixture-cached-key"
        settings.theme = "dark"
        _ = try await store.save(settings)

        // Model another settings owner writing newer preferences after this
        // store cached its model. A column toggle must not save that old model.
        let defaults = store.defaults.defaults
        defaults.set(true, forKey: "blockAddWhenLoading")
        defaults.set("fixture-newer-key", forKey: "apiAuthKey")
        defaults.set("light", forKey: "theme")
        defaults.set(65_536, forKey: "speedLimit")
        defaults.set("keep-unknown-preference", forKey: "fixture.unrelated")
        var expected = defaults.dictionaryRepresentation()
        for visible in [true, false] {
            let updated = try await store.saveShowDownloadLocation(visible)
            #expect(updated.showDownloadLocation == visible)
            expected["showDownloadLocation"] = visible
            #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()).isEqual(to: expected))
            let reopened = try await SettingsStore(dataRoot: root).load()
            #expect(reopened.showDownloadLocation == visible)
            #expect(reopened.blockAddWhenLoading)
            #expect(reopened.apiAuthKey == "fixture-newer-key")
            #expect(reopened.theme == "light")
            #expect(reopened.speedLimit == 65_536)
            #expect(defaults.string(forKey: "fixture.unrelated") == "keep-unknown-preference")
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cooldm-upstream112-settings-\(UUID().uuidString)", isDirectory: true)
    }
}
