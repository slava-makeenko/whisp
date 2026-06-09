import Testing
@testable import WhispCore

@Suite("Update status")
struct UpdateStatusTests {
    @Test("idle status is not sidebar-visible")
    func idleStatusIsNotSidebarVisible() {
        #expect(UpdateStatus.idle.isSidebarVisible == false)
        #expect(UpdateStatus.idle.sidebarMessage == nil)
        #expect(UpdateStatus.idle.actionTitle == nil)
    }

    @Test("downloading status exposes progress text")
    func downloadingStatusExposesProgressText() {
        let status = UpdateStatus.downloading(progress: 0.42)

        #expect(status.isSidebarVisible)
        #expect(status.sidebarMessage == "Downloading update… 42%")
        #expect(status.actionTitle == nil)
    }

    @Test("ready status exposes accent action")
    func readyStatusExposesAccentAction() {
        let status = UpdateStatus.readyToInstall(version: "0.1.2")

        #expect(status.isSidebarVisible)
        #expect(status.sidebarMessage == "Update 0.1.2 is ready")
        #expect(status.actionTitle == "Restart to Update")
    }

    @Test("checking status can be shown in settings")
    func checkingStatusMessage() {
        #expect(UpdateStatus.checking.settingsMessage == "Checking for updates…")
    }
}
