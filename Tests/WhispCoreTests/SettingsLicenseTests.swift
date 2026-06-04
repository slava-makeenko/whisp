import Testing
import Foundation
import WhispASR
@testable import WhispCore

@Suite struct SettingsLicenseTests {

    @Test func settingsRoundTripExcludesSecrets() throws {
        let backup = SettingsBackup(
            profiles: [PowerProfile(name: "Mail", rules: [ContextRule(kind: .urlHost, value: "gmail.com")])],
            hotkeyKeyCode: 49, hotkeyModifiers: 2, enhancementEnabled: true, defaultPrompt: "Fix grammar.")

        let data = try backup.exportJSON()
        #expect(try SettingsBackup.from(data) == backup)

        // No secret-bearing keys are present in the serialized form.
        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("apikey"))
        #expect(!json.contains("license"))
    }

    @Test func trialCountsDownThenExpires() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let day5 = Calendar.current.date(byAdding: .day, value: 5, to: start)!
        let day20 = Calendar.current.date(byAdding: .day, value: 20, to: start)!

        #expect(LicenseEvaluator.evaluate(firstLaunch: start, now: day5, trialDays: 14, licenseKey: nil)
                == .trial(daysLeft: 9))
        #expect(LicenseEvaluator.evaluate(firstLaunch: start, now: day20, trialDays: 14, licenseKey: nil)
                == .expired)
    }

    @Test func nonEmptyKeyIsLicensed() {
        #expect(LicenseEvaluator.evaluate(firstLaunch: .now, licenseKey: "ABC-123") == .licensed)
    }
}
