import Testing
import Foundation
import WhispPlatform
@testable import WhispCore

@Suite struct PowerModeTests {
    private let safari = AppContext(bundleID: "com.apple.Safari", appName: "Safari",
                                    url: URL(string: "https://mail.google.com/inbox"))
    private let xcode = AppContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode", url: nil)

    @Test func bundleIDRuleMatches() {
        let profile = PowerProfile(name: "Code", rules: [ContextRule(kind: .bundleID, value: "com.apple.dt.Xcode")])
        #expect(profile.matches(xcode))
        #expect(!profile.matches(safari))
    }

    @Test func urlHostRuleMatches() {
        let profile = PowerProfile(name: "Mail", rules: [ContextRule(kind: .urlHost, value: "mail.google.com")])
        #expect(profile.matches(safari))
        #expect(!profile.matches(xcode))
    }

    @Test func resolverPicksFirstMatch() {
        let resolver = PowerModeResolver()
        let mail = PowerProfile(name: "Mail", rules: [ContextRule(kind: .urlHost, value: "google.com")])
        let code = PowerProfile(name: "Code", rules: [ContextRule(kind: .bundleID, value: "com.apple.dt.Xcode")])
        #expect(resolver.resolve(safari, profiles: [mail, code])?.name == "Mail")
        #expect(resolver.resolve(xcode, profiles: [mail, code])?.name == "Code")
        #expect(resolver.resolve(AppContext(bundleID: "other", appName: nil, url: nil), profiles: [mail, code]) == nil)
    }

    @MainActor
    @Test func managerFiresOnChangeOnlyWhenProfileChanges() {
        final class Box { var count = 0 }
        let box = Box()
        let manager = PowerModeManager(
            profiles: [PowerProfile(name: "Code", rules: [ContextRule(kind: .bundleID, value: "com.apple.dt.Xcode")])],
            onChange: { _ in box.count += 1 })

        manager.update(xcode)
        #expect(manager.activeProfile?.name == "Code")
        #expect(box.count == 1)

        manager.update(xcode)            // same profile → no fire
        #expect(box.count == 1)

        manager.update(safari)           // no match → cleared, fires
        #expect(manager.activeProfile == nil)
        #expect(box.count == 2)
    }
}
