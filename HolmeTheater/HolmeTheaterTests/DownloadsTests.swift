// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import HolmeTheater

struct DownloadStateTests {
    @Test func progressStageFlags() {
        #expect(DownloadState.queued.isInProgress)
        #expect(DownloadState.downloading.isInProgress)
        #expect(!DownloadState.paused.isInProgress)
        #expect(DownloadState.paused.isStalled)
        #expect(DownloadState.failed.isStalled)
        #expect(!DownloadState.completed.isStalled)
    }

    @Test func progressClampsAndRespectsEstimates() {
        var record = Sample.record(Sample.movie(id: "m"), state: .downloading)
        record.bytesExpected = 100
        record.bytesWritten = 50
        #expect(record.progress == 0.5)
        // An estimate that is too small never claims to be finished.
        record.isSizeEstimated = true
        record.bytesWritten = 200
        #expect(record.progress == 0.99)
    }

    @Test func statusDescriptionReflectsState() {
        var record = Sample.record(Sample.movie(), state: .failed)
        record.errorMessage = "Nope"
        #expect(record.statusDescription == "Nope")
        record.state = .completed
        #expect(record.statusDescription.isEmpty)
    }
}

struct DownloadSummaryTests {
    @Test func countsCompletionAndMovementPerContainer() {
        let done = Sample.record(Sample.episode(id: "e1", seriesID: "s", seasonID: "a", episodeNumber: 1), state: .completed)
        let moving = Sample.record(Sample.episode(id: "e2", seriesID: "s", seasonID: "a", episodeNumber: 2), state: .downloading)
        let movie = Sample.record(Sample.movie(id: "m"), state: .completed)
        let summary = DownloadSummary(records: [done, moving, movie])

        #expect(summary.completedIDs == ["e1", "m"])
        #expect(summary.activeCount == 1)
        #expect(summary.completedEpisodeCounts["s"] == 1)
        #expect(summary.movingIDs.contains("s"))
        #expect(summary.unfinishedContainerIDs.contains("a"))
        #expect(summary.recordCounts["s"] == 2)
    }
}

struct DownloadBatchProgressTests {
    @Test func emptyBatchHasNoProgress() {
        #expect(DownloadBatchProgress(members: []) == nil)
    }

    @Test func oneDownloadUsesItsTitle() {
        let record = Sample.record(Sample.movie(id: "m", title: "Solo"), state: .downloading)
        let progress = DownloadBatchProgress(members: [record])
        #expect(progress?.title == "Solo")
        #expect(progress?.total == 1)
        #expect(progress?.isFinished == false)
    }

    @Test func manyDownloadsReportCompletionAndFinish() {
        let a = Sample.record(Sample.movie(id: "a"), state: .completed)
        let b = Sample.record(Sample.movie(id: "b"), state: .completed)
        let progress = DownloadBatchProgress(members: [a, b])
        #expect(progress?.completed == 2)
        #expect(progress?.fraction == 1)
        #expect(progress?.isFinished == true)
    }
}

struct DownloadLibraryTests {
    private func library() -> [DownloadRecord] {
        [
            Sample.record(Sample.movie(id: "m2", title: "Bravo")),
            Sample.record(Sample.movie(id: "m1", title: "Alpha")),
            Sample.record(Sample.episode(id: "s1e2", seriesID: "show", seasonID: "s1", seasonNumber: 1, episodeNumber: 2)),
            Sample.record(Sample.episode(id: "s1e1", seriesID: "show", seasonID: "s1", seasonNumber: 1, episodeNumber: 1)),
            Sample.record(Sample.episode(id: "s2e1", seriesID: "show", seasonID: "s2", seasonNumber: 2, episodeNumber: 1)),
            // An unfinished download is left out of the finished library.
            Sample.record(Sample.movie(id: "m3"), state: .downloading)
        ]
    }

    @Test func moviesComeBackSortedByName() {
        #expect(DownloadLibrary.movies(from: library()).map(\.item.id) == ["m1", "m2"])
    }

    @Test func showsGroupEpisodesAndUseTheGivenTitle() {
        let shows = DownloadLibrary.shows(from: library()) { $0 == "show" ? "My Show" : nil }
        #expect(shows.count == 1)
        #expect(shows.first?.title == "My Show")
        #expect(shows.first?.episodes.map(\.id) == ["s1e1", "s1e2", "s2e1"])
    }

    @Test func seasonsAndEpisodesAreOrdered() {
        let seasons = DownloadLibrary.seasons(ofSeries: "show", from: library())
        #expect(seasons.map(\.id) == ["s1", "s2"])
        #expect(DownloadLibrary.episodes(ofSeason: "s1", from: library()).map(\.id) == ["s1e1", "s1e2"])
    }
}

struct DownloadFileNamingTests {
    @Test func keepsPlayableContainersOtherwiseMP4() {
        #expect(DownloadFileNaming.videoExtension(suggestedFilename: "movie.mkv") == "mp4")
        #expect(DownloadFileNaming.videoExtension(suggestedFilename: "movie.mov") == "mov")
        #expect(DownloadFileNaming.videoExtension(suggestedFilename: nil) == "mp4")
    }

    @Test func subtitleFileNameMatchesFormat() {
        #expect(DownloadFileNaming.subtitleFileName(trackIndex: 3, format: .pgs) == "subtitles-3.sup")
        #expect(DownloadFileNaming.subtitleFileName(trackIndex: 1, format: .ass) == "subtitles-1.ass")
        #expect(DownloadFileNaming.subtitleFileName(trackIndex: 2, format: nil) == "subtitles-2.vtt")
    }
}
