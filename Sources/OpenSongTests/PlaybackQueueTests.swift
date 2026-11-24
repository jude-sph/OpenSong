import Foundation
import OpenSongCore

func registerPlaybackQueueTests() {
    t.test("normal play runs the queue through once and stops") {
        try t.expectEqual(PlaybackQueue.afterFinishing(index: 0, count: 3, repeatMode: .off), 1,
                          "mid-queue, carry on")
        try t.expect(PlaybackQueue.afterFinishing(index: 2, count: 3, repeatMode: .off) == nil,
                     "the last track ends playback")
        try t.expect(PlaybackQueue.afterSkip(index: 2, count: 3, repeatMode: .off) == nil,
                     "and skip does nothing there")
        try t.expect(PlaybackQueue.beforeSkip(index: 0, count: 3, repeatMode: .off) == nil,
                     "nor does skipping back from the first")
    }

    t.test("repeat queue wraps round in both directions") {
        try t.expectEqual(PlaybackQueue.afterFinishing(index: 2, count: 3, repeatMode: .all), 0,
                          "the last track rolls into the first")
        try t.expectEqual(PlaybackQueue.afterSkip(index: 2, count: 3, repeatMode: .all), 0,
                          "skip forward wraps")
        try t.expectEqual(PlaybackQueue.beforeSkip(index: 0, count: 3, repeatMode: .all), 2,
                          "skip back wraps to the end")
        try t.expectEqual(PlaybackQueue.afterFinishing(index: 0, count: 3, repeatMode: .all), 1,
                          "and mid-queue is unchanged")
    }

    t.test("repeat one replays on its own but still skips when asked") {
        try t.expectEqual(PlaybackQueue.afterFinishing(index: 1, count: 3, repeatMode: .one), 1,
                          "finishing replays the same track")
        try t.expectEqual(PlaybackQueue.afterFinishing(index: 2, count: 3, repeatMode: .one), 2,
                          "including the last one")
        // A skip button that replayed the same track would look broken, so repeat-one doesn't apply
        // to an explicit press.
        try t.expectEqual(PlaybackQueue.afterSkip(index: 1, count: 3, repeatMode: .one), 2,
                          "skip forward still moves on")
        try t.expectEqual(PlaybackQueue.afterSkip(index: 2, count: 3, repeatMode: .one), 0,
                          "and wraps at the end")
        try t.expectEqual(PlaybackQueue.beforeSkip(index: 0, count: 3, repeatMode: .one), 2,
                          "skip back wraps too")
    }

    t.test("a single-track queue behaves in every mode") {
        try t.expect(PlaybackQueue.afterFinishing(index: 0, count: 1, repeatMode: .off) == nil, "off: stop")
        try t.expectEqual(PlaybackQueue.afterFinishing(index: 0, count: 1, repeatMode: .all), 0, "all: again")
        try t.expectEqual(PlaybackQueue.afterFinishing(index: 0, count: 1, repeatMode: .one), 0, "one: again")
        try t.expectEqual(PlaybackQueue.afterSkip(index: 0, count: 1, repeatMode: .all), 0,
                          "skip has nowhere else to go")
    }

    t.test("an empty or out-of-range queue yields nothing rather than crashing") {
        for mode in RepeatMode.allCases {
            try t.expect(PlaybackQueue.afterFinishing(index: 0, count: 0, repeatMode: mode) == nil,
                         "\(mode): empty queue")
            try t.expect(PlaybackQueue.afterSkip(index: 7, count: 3, repeatMode: mode) == nil,
                         "\(mode): index past the end")
            try t.expect(PlaybackQueue.beforeSkip(index: -1, count: 3, repeatMode: mode) == nil,
                         "\(mode): negative index")
        }
    }

    t.test("the button cycles off → repeat queue → repeat one → off") {
        try t.expectEqual(RepeatMode.off.next, .all, "off → all")
        try t.expectEqual(RepeatMode.all.next, .one, "all → one")
        try t.expectEqual(RepeatMode.one.next, .off, "one → off")
        try t.expectEqual(RepeatMode(rawValue: "all"), .all, "round-trips for saving")
    }
}

func registerRowDragTests() {
    t.test("a dragged row lands where the pointer is, not where it has been") {
        // Half a row either way rounds to the nearest slot.
        try t.expectEqual(RowDrag.targetIndex(startIndex: 2, translation: 41, rowStride: 41, count: 6), 3,
                          "one row down")
        try t.expectEqual(RowDrag.targetIndex(startIndex: 2, translation: -41, rowStride: 41, count: 6), 1,
                          "one row up")
        try t.expectEqual(RowDrag.targetIndex(startIndex: 2, translation: 20, rowStride: 41, count: 6), 2,
                          "less than half a row doesn't move it")
        try t.expectEqual(RowDrag.targetIndex(startIndex: 2, translation: 25, rowStride: 41, count: 6), 3,
                          "more than half does")
        // The old drag-and-drop version lost the reorder if you overshot the list or doubled back.
        try t.expectEqual(RowDrag.targetIndex(startIndex: 2, translation: 9999, rowStride: 41, count: 6), 5,
                          "overshooting the bottom clamps to the last row")
        try t.expectEqual(RowDrag.targetIndex(startIndex: 2, translation: -9999, rowStride: 41, count: 6), 0,
                          "and the top clamps to the first")
        try t.expectEqual(RowDrag.targetIndex(startIndex: 2, translation: 0, rowStride: 41, count: 6), 2,
                          "coming back to where it started is a no-op, not a lost drag")
    }

    t.test("a degenerate list or stride can't produce a bad index") {
        try t.expectEqual(RowDrag.targetIndex(startIndex: 0, translation: 100, rowStride: 0, count: 3), 0,
                          "a zero stride would otherwise divide by zero")
        try t.expectEqual(RowDrag.targetIndex(startIndex: 0, translation: 100, rowStride: 41, count: 0), 0,
                          "an empty playlist")
    }

    t.test("reordering moves exactly one row and keeps the rest in order") {
        let ids: [Int64] = [10, 20, 30, 40]
        try t.expectEqual(RowDrag.reorder(ids, from: 3, to: 0), [40, 10, 20, 30], "last to first")
        try t.expectEqual(RowDrag.reorder(ids, from: 0, to: 3), [20, 30, 40, 10], "first to last")
        try t.expectEqual(RowDrag.reorder(ids, from: 1, to: 1), ids, "no move, no change")
        try t.expectEqual(RowDrag.reorder(ids, from: 9, to: 0), ids, "out of range is left alone")
    }
}
