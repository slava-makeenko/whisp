import Foundation
import Observation

/// Download state for a single model.
public enum ModelDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)   // 0…1
    case downloaded
    case failed(String)
}

/// Manages on-device model files: download, storage, selection, and status.
/// Downloads run via URLSession background tasks and survive app restarts.
@MainActor
@Observable
public final class LocalModelStore: NSObject, Sendable {

    // MARK: - Public state

    public private(set) var states: [String: ModelDownloadState] = [:]
    public private(set) var activeModelID: String? {
        didSet { UserDefaults.standard.set(activeModelID, forKey: Keys.activeModel) }
    }

    // MARK: - Private

    private var sessions:  [String: URLSession] = [:]
    private var tasks:     [String: URLSessionDownloadTask] = [:]
    private var tempURLs:  [String: URL] = [:]

    private static let modelsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("whisp/OnDeviceModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private enum Keys {
        static let activeModel = "localModelID"
    }

    // MARK: - Init

    public override init() {
        super.init()
        activeModelID = UserDefaults.standard.string(forKey: Keys.activeModel)
        refreshStates()
    }

    // MARK: - Public API

    public func localURL(for model: OnDeviceModel) -> URL {
        Self.modelsDir.appendingPathComponent(model.filename)
    }

    public func isDownloaded(_ model: OnDeviceModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    public func startDownload(_ model: OnDeviceModel) {
        guard states[model.id] != .downloading(progress: 0) else { return }
        let config = URLSessionConfiguration.background(withIdentifier: "whisp.model.\(model.id)")
        config.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        sessions[model.id] = session
        let task = session.downloadTask(with: model.downloadURL)
        tasks[model.id] = task
        states[model.id] = .downloading(progress: 0)
        task.resume()
    }

    public func cancelDownload(_ model: OnDeviceModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        sessions[model.id]?.invalidateAndCancel()
        sessions[model.id] = nil
        states[model.id] = .notDownloaded
    }

    public func delete(_ model: OnDeviceModel) {
        cancelDownload(model)
        try? FileManager.default.removeItem(at: localURL(for: model))
        states[model.id] = .notDownloaded
        if activeModelID == model.id { activeModelID = nil }
    }

    public func select(_ model: OnDeviceModel) {
        guard isDownloaded(model) else { return }
        activeModelID = model.id
    }

    public var activeModel: OnDeviceModel? {
        guard let id = activeModelID else { return nil }
        return OnDeviceModel.catalog.first { $0.id == id }
    }

    // MARK: - Private helpers

    private func refreshStates() {
        for model in OnDeviceModel.catalog {
            if case .downloading = states[model.id] { continue }
            states[model.id] = isDownloaded(model) ? .downloaded : .notDownloaded
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension LocalModelStore: URLSessionDownloadDelegate {

    public nonisolated func urlSession(_ session: URLSession,
                                       downloadTask: URLSessionDownloadTask,
                                       didWriteData: Int64,
                                       totalBytesWritten: Int64,
                                       totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let modelID = session.configuration.identifier?.replacingOccurrences(of: "whisp.model.", with: "") ?? ""
        Task { @MainActor [weak self] in
            self?.states[modelID] = .downloading(progress: progress)
        }
    }

    public nonisolated func urlSession(_ session: URLSession,
                                       downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        let modelID = session.configuration.identifier?.replacingOccurrences(of: "whisp.model.", with: "") ?? ""
        guard let model = OnDeviceModel.catalog.first(where: { $0.id == modelID }) else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisp/OnDeviceModels", isDirectory: true)
        let dest = dir.appendingPathComponent(model.filename)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.states[modelID] = .downloaded
                self.tasks[modelID] = nil
                // Auto-select if no model is active yet
                if self.activeModelID == nil { self.activeModelID = modelID }
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.states[modelID] = .failed(error.localizedDescription)
            }
        }
    }

    public nonisolated func urlSession(_ session: URLSession,
                                       task: URLSessionTask,
                                       didCompleteWithError error: Error?) {
        guard let error else { return }
        let modelID = session.configuration.identifier?.replacingOccurrences(of: "whisp.model.", with: "") ?? ""
        let isCancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor [weak self] in
            self?.states[modelID] = isCancelled ? .notDownloaded : .failed(error.localizedDescription)
        }
    }
}
