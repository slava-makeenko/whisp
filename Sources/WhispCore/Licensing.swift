import Foundation

public enum LicenseState: Sendable, Equatable {
    case trial(daysLeft: Int)
    case licensed
    case expired
}

/// Pure trial/licensing evaluation. A non-empty stored key counts as licensed; otherwise the
/// trial counts down from first launch. Server-side key validation is deferred (P2).
public enum LicenseEvaluator {
    public static func evaluate(firstLaunch: Date, now: Date = .now,
                                trialDays: Int = 14, licenseKey: String?) -> LicenseState {
        if let licenseKey, !licenseKey.isEmpty { return .licensed }
        let elapsed = Calendar.current.dateComponents([.day], from: firstLaunch, to: now).day ?? 0
        let daysLeft = trialDays - elapsed
        return daysLeft > 0 ? .trial(daysLeft: daysLeft) : .expired
    }
}
