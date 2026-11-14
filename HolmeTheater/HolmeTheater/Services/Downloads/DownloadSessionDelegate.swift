// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Synchronization

/// How a downloaded video and its subtitle files are named on disk.
nonisolated enum DownloadFileNaming {
    /// The containers AVPlayer plays as they are, which a saved file keeps the name of.
    private static let playableExtensions: Set<String> = ["mp4", "m4v", "mov"]

    /// The video file's extension, which the player needs to recognize what it is. The server's own name for it, if
    /// that's one it can play, otherwise MP4.
    static func videoExtension(suggestedFilename: String?) -> String {
        let suggested = (suggestedFilename as NSString?)?.pathExtension.lowercased() ?? ""
        return playableExtensions.contains(suggested) ? suggested : "mp4"
    }

    /// The name a subtitle track's file is saved under, by its track index and format.
    static func subtitleFileName(trackIndex: Int, format: SubtitleFormat?) -> String {
        let fileExtension = switch format {
        case .pgs: "sup"
        case .ass: "ass"
        case .webVTT, nil: "vtt"
        }
        return "subtitles-\(trackIndex).\(fileExtension)"
    }
}

/// Receives a background session's callbacks, which come on a queue of its own, and saves each finished file at once:
/// the system deletes it as soon as the callback returns.
nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    /// What a transfer did. Each names its download by ``DownloadStore/key(scope:id:)``, since the account may have
    /// changed since it started.
    enum Event: Sendable {
        case progress(key: String, written: Int64, expected: Int64)
        case finished(key: String)
        case failed(key: String, message: String)
        /// Cancelled by the user: paused or removed, which whoever did it has dealt with.
        case cancelled(key: String)
        /// Cancelled by the system while it was meant to be downloading, e.g. when the app was force quit.
        case interrupted(key: String)
    }

    private let store: DownloadStore
    private let backgroundEvents: BackgroundEvents
    /// When each transfer last reported progress, by key.
    private let lastProgress = Mutex<[String: Date]>([:])
    private let eventHandler = Mutex<(@Sendable (Event) -> Void)?>(nil)

    /// Set once, right after creating the session.
    var onEvent: (@Sendable (Event) -> Void)? {
        get { eventHandler.withLock { $0 } }
        set { eventHandler.withLock { $0 = newValue } }
    }

    init(store: DownloadStore, backgroundEvents: BackgroundEvents) {
        self.store = store
        self.backgroundEvents = backgroundEvents
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = key(of: downloadTask) else { return }
        // Many times a second otherwise, and each one redraws the screen.
        let isDue = lastProgress.withLock { lastProgress -> Bool in
            let now = Date.now
            if let last = lastProgress[key], now.timeIntervalSince(last) < 0.25 { return false }
            lastProgress[key] = now
            return true
        }
        guard isDue else { return }
        onEvent?(.progress(key: key, written: totalBytesWritten, expected: totalBytesExpectedToWrite))
    }

    /// The download a transfer is for, by ``DownloadStore/key(scope:id:)``.
    private func key(of task: URLSessionTask) -> String? {
        guard let description = task.taskDescription else { return nil }
        let (scope, id) = store.parse(key: description)
        return DownloadStore.key(scope: scope, id: id)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = key(of: downloadTask), store.record(key: key) != nil else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onEvent?(.failed(key: key, message: String(localized: "The server returned an error (\(http.statusCode)).")))
            return
        }
        do {
            let directory = try store.makeItemDirectory(key: key)
            let name = "video." + DownloadFileNaming.videoExtension(suggestedFilename: downloadTask.response?.suggestedFilename)
            let destination = directory.appending(path: name, directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64) ?? 0
            store.update(key: key) {
                $0.videoFileName = name
                $0.fileSize = size
                $0.bytesWritten = size
                $0.bytesExpected = size
                $0.state = .completed
                $0.errorMessage = nil
            }
            // On disk before returning: the app may be suspended straight after, and a download still marked as
            // downloading would be fetched all over again.
            store.flush()
            lastProgress.withLock { $0[key] = nil }
            onEvent?(.finished(key: key))
        } catch {
            onEvent?(.failed(key: key, message: error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = key(of: task) else { return }
        let nsError = error as NSError
        lastProgress.withLock { $0[key] = nil }

        // Wherever the transfer got to is kept, so trying again carries on from there.
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            store.saveResumeData(data, key: key, request: task.originalRequest)
        }

        // Pausing marks the record first, and removing deletes it first, so a cancellation of a download that's still
        // meant to be downloading came from the system.
        let state = store.record(key: key)?.state
        if state == nil || state == .paused {
            onEvent?(.cancelled(key: key))
        } else if nsError.code == NSURLErrorCancelled {
            onEvent?(state == .downloading ? .interrupted(key: key) : .cancelled(key: key))
        } else {
            onEvent?(.failed(key: key, message: error.localizedDescription))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // The system suspends the app again once it hears this has finished.
        store.flush()
        backgroundEvents.markFinished()
    }
}
