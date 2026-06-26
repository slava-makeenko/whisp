import Foundation
import AVFoundation

/// Prepares a dropped/picked file for transcription. Audio files pass straight through; video
/// containers (which the ASR backends can't decode directly) have their audio track exported to a
/// temporary `.m4a` first. Resolves VERIFY-FILE-1.
public enum MediaPreparer {

    /// Returns a temporary `.m4a` of `url`'s audio track when `url` is a video, otherwise `nil`
    /// (the caller transcribes the original). The caller owns the returned file and deletes it.
    public static func extractedAudioURL(for url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        // Only extract when there's a video track — plain audio is read directly by the backends.
        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              !videoTracks.isEmpty,
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              !audioTracks.isEmpty else { return nil }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisp-extract-\(UUID().uuidString).m4a")
        export.outputURL = output
        export.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        return export.status == .completed ? output : nil
    }
}
