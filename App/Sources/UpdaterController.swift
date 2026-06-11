import SwiftUI
import Sparkle
import Combine
import WhispCore

/// Thin wrapper over Sparkle's updater. No-op in LOCAL_BUILD (dev) — there is no
/// feed or signing in development. Release builds expose enough state for whisp's
/// sidebar/settings while still letting Sparkle's standard UI handle release notes,
/// permissions, and install prompts.
/// `@MainActor`: Sparkle 2.9.2's updater APIs are main-actor isolated.
@MainActor
final class UpdaterController: ObservableObject {
    @Published var canCheckForUpdates = false
    @Published var status: UpdateStatus = .idle

    private var updater: SPUUpdater?
    #if !LOCAL_BUILD
    private var userDriver: TrackingSparkleUserDriver?
    #endif
    private var cancellables: Set<AnyCancellable> = []

    init() {
        #if LOCAL_BUILD
        updater = nil
        #else
        let driver = TrackingSparkleUserDriver(hostBundle: .main)
        driver.onStatusChange = { [weak self] status in self?.status = status }
        driver.onReadyToInstall = { [weak self] install in self?.installReadyUpdate = install }
        userDriver = driver

        let sparkleUpdater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        updater = sparkleUpdater
        sparkleUpdater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        do {
            try sparkleUpdater.start()
        } catch {
            status = .failed("Updates are not configured correctly: \(error.localizedDescription)")
        }
        #endif
    }

    private var installReadyUpdate: (() -> Void)?

    func checkForUpdates() {
        status = .checking
        updater?.checkForUpdates()
    }

    func installUpdate() {
        installReadyUpdate?()
    }
}

#if !LOCAL_BUILD
@MainActor
private final class TrackingSparkleUserDriver: NSObject, SPUUserDriver {
    var onStatusChange: ((UpdateStatus) -> Void)?
    var onReadyToInstall: (((() -> Void)?) -> Void)?

    private let standard: SPUStandardUserDriver
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var updateVersion: String?

    init(hostBundle: Bundle) {
        standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onStatusChange?(.checking)
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateVersion = appcastItem.displayVersionString
        onStatusChange?(.available(version: appcastItem.displayVersionString))
        standard.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            if choice == .install {
                self?.onStatusChange?(.downloading(progress: 0))
            } else {
                self?.onStatusChange?(.idle)
            }
            reply(choice)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standard.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFound { [weak self] in
            self?.onStatusChange?(.idle)
            acknowledgement()
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        onStatusChange?(.failed(error.localizedDescription))
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedContentLength = 0
        receivedContentLength = 0
        onStatusChange?(.downloading(progress: 0))
        standard.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        if expectedContentLength > 0 {
            onStatusChange?(.downloading(progress: Double(receivedContentLength) / Double(expectedContentLength)))
        } else {
            onStatusChange?(.downloading(progress: 0))
        }
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        onStatusChange?(.extracting(progress: 0))
        standard.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onStatusChange?(.extracting(progress: progress))
        standard.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var didReply = false
        let finish: (SPUUserUpdateChoice) -> Void = { [weak self] choice in
            guard !didReply else { return }
            didReply = true
            self?.readyReply = nil
            if choice == .install {
                self?.onStatusChange?(.installing)
            } else {
                self?.onStatusChange?(.idle)
            }
            reply(choice)
        }
        readyReply = finish
        onStatusChange?(.readyToInstall(version: updateVersion))
        onReadyToInstall?({ [weak self] in
            guard let self, let readyReply = self.readyReply else { return }
            readyReply(.install)
        })
        standard.showReady(toInstallAndRelaunch: finish)
    }


    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        onStatusChange?(.installing)
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        onStatusChange?(.idle)
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        onStatusChange?(.idle)
        standard.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        standard.showUpdateInFocus()
    }
}
#endif
