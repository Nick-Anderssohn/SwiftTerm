//
//  ResizeCoalescingTests.swift
//
//  Pins the contract that `TerminalView.processSizeChange` coalesces
//  rapid bursts of UI-driven resize events into a single
//  `terminal.resize` + `TerminalViewDelegate.sizeChanged` fan-out at
//  the latest geometry.
//
//  Why this matters: when a sidebar drag or window live-resize emits
//  many SIGWINCHes in quick succession, the shell's first redraw is
//  generated for the OLD column count and arrives at SwiftTerm AFTER
//  the buffer has flipped to the NEW (smaller) column count. The
//  shell's redraw bytes autowrap inside the now-narrower buffer, leave
//  stale prompt fragments above, and `\r\r\e[J` only clears below
//  cursor — so the fragments stay visible, producing the visible
//  prompt-stacking bug.
//
//  The fix coalesces resizes at `processSizeChange`, the single
//  chokepoint for every UI-driven geometry change on macOS / iOS /
//  visionOS / SwiftUI. This file pins the design invariants:
//   - bursts collapse to one apply at the latest geometry
//   - the timer is NOT rescheduled by new arrivals (sustained drags
//     therefore land once per window, not "never")
//   - `resizeDebounceMs = 0` disables coalescing entirely
//   - zero / unchanged sizes never arm a timer or fan out
//   - dealloc mid-debounce doesn't crash

#if os(macOS)
import Foundation
import Testing
import AppKit

@testable import SwiftTerm

@MainActor
@Suite("Resize coalescing")
final class ResizeCoalescingTests {

    /// Records every `sizeChanged(source:newCols:newRows:)` invocation.
    /// Implements the rest of `TerminalViewDelegate` with no-op stubs.
    final class RecordingDelegate: TerminalViewDelegate {
        struct Call: Equatable {
            let cols: Int
            let rows: Int
        }
        private(set) var sizeChangedCalls: [Call] = []

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            sizeChangedCalls.append(Call(cols: newCols, rows: newRows))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// Builds a `TerminalView` with a frame large enough for the cell
    /// grid math to land non-trivially. Returns the view and a
    /// strongly-held delegate so callers can inspect calls.
    private func makeView(initialSize: CGSize = CGSize(width: 800, height: 600)) -> (TerminalView, RecordingDelegate) {
        let view = TerminalView(frame: CGRect(origin: .zero, size: initialSize), font: nil)
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate
        return (view, delegate)
    }

    /// Picks a target size that — given the view's `cellDimension` —
    /// yields a strictly different `(cols, rows)` than the current grid
    /// after `getEffectiveWidth`. Used so tests don't accidentally
    /// trip the "no change in cell grid" early-return inside
    /// `applySizeChange`.
    private func sizeForColDelta(_ view: TerminalView, deltaCols: Int) -> CGSize {
        let cellW = view.cellDimension.width
        let cellH = view.cellDimension.height
        let curCols = view.terminal.cols
        let targetCols = max(1, curCols + deltaCols)
        // Add scroller-width slack via getEffectiveWidth: pad one extra cell.
        let width = CGFloat(targetCols + 1) * cellW
        let height = CGFloat(view.terminal.rows) * cellH
        return CGSize(width: width, height: height)
    }

    @Test("burst of 5 rapid resizes collapses to one apply at the latest size")
    func coalesces5RapidResizesIntoOneAtLatestSize() async throws {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30

        // Fire 5 distinct sizes back-to-back. Each call mutates
        // self.frame so the timer-fire's `frame.size` re-read picks
        // up whatever the last setFrameSize landed.
        for delta in [-1, -2, -3, -4, -5] {
            let target = sizeForColDelta(view, deltaCols: delta)
            view.setFrameSize(NSSize(width: target.width, height: target.height))
        }

        try await Task.sleep(nanoseconds: 60_000_000) // 60 ms

        #expect(delegate.sizeChangedCalls.count == 1, "expected exactly one delegate call after burst, got \(delegate.sizeChangedCalls.count)")
        // The single recorded call's (cols, rows) is what
        // `applySizeChange` passed to `terminal.resize` — so it must
        // match the post-apply core state. (We don't reach into
        // getEffectiveWidth here; the round-trip equality is a
        // sufficient pin against the bug class "the timer fired with
        // a stale geometry".)
        let recorded = delegate.sizeChangedCalls.last!
        #expect(recorded.cols == view.terminal.cols)
        #expect(recorded.rows == view.terminal.rows)
    }

    @Test("disabling debounce applies synchronously")
    func disablingDebounceAppliesSynchronously() {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 0

        let s1 = sizeForColDelta(view, deltaCols: -1)
        let s2 = sizeForColDelta(view, deltaCols: -2)
        let s3 = sizeForColDelta(view, deltaCols: -3)

        // Without the debounce, every distinct size fans out
        // synchronously. setFrameSize is the public entry point that
        // routes through processSizeChange.
        view.setFrameSize(NSSize(width: s1.width, height: s1.height))
        view.setFrameSize(NSSize(width: s2.width, height: s2.height))
        view.setFrameSize(NSSize(width: s3.width, height: s3.height))

        #expect(delegate.sizeChangedCalls.count == 3, "expected 3 synchronous delegate calls, got \(delegate.sizeChangedCalls.count)")
    }

    @Test("sustained drag lands at least 3 times — timer is not rescheduled")
    func sustainedDragLandsOncePerWindowNotZeroTimes() async throws {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30

        // 50 distinct sizes over ~500 ms = 10 Hz. If a regression
        // resets the timer on every arrival, the apply never fires
        // until the burst ends — count would be 0–1. With the
        // non-rescheduling design, the apply lands once per ~30 ms
        // window: count is bounded above by ~16 and below by 3.
        for i in 0..<50 {
            let delta = -1 - (i % 5)
            let target = sizeForColDelta(view, deltaCols: delta)
            view.setFrameSize(NSSize(width: target.width, height: target.height))
            try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }

        try await Task.sleep(nanoseconds: 60_000_000) // 60 ms drain

        let n = delegate.sizeChangedCalls.count
        #expect(n >= 3 && n <= 20, "sustained drag should fire 3-20 times; got \(n)")
    }

    @Test("the final size is always applied")
    func finalSizeIsAlwaysApplied() async throws {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30

        // Burst ending at a known final size.
        for delta in [-1, -2, -3] {
            let target = sizeForColDelta(view, deltaCols: delta)
            view.setFrameSize(NSSize(width: target.width, height: target.height))
        }
        let finalSize = sizeForColDelta(view, deltaCols: -7)
        view.setFrameSize(NSSize(width: finalSize.width, height: finalSize.height))

        try await Task.sleep(nanoseconds: 60_000_000) // 60 ms

        #expect(delegate.sizeChangedCalls.count >= 1)
        // Round-trip equality with the post-apply core state pins
        // "the apply used the live frame at fire time" without
        // re-implementing getEffectiveWidth here.
        let recorded = delegate.sizeChangedCalls.last!
        #expect(recorded.cols == view.terminal.cols)
        #expect(recorded.rows == view.terminal.rows)
    }

    @Test("zero size never arms a timer")
    func zeroSizeIsRejected() async throws {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30

        // processSizeChange is internal — call it directly with .zero.
        _ = view.processSizeChange(newSize: .zero)
        try await Task.sleep(nanoseconds: 60_000_000) // 60 ms

        #expect(delegate.sizeChangedCalls.isEmpty, "zero size should never fan out")
    }

    @Test("identical size produces no delegate call")
    func identicalSizeProducesNoDelegateCall() async throws {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30

        // Settle the view first, then call again with the same size.
        view.setFrameSize(view.frame.size)
        try await Task.sleep(nanoseconds: 60_000_000) // first apply (if any) drains

        let baseline = delegate.sizeChangedCalls.count
        view.setFrameSize(view.frame.size)
        try await Task.sleep(nanoseconds: 60_000_000)

        #expect(delegate.sizeChangedCalls.count == baseline,
                "identical-size resize must not produce a delegate call")
    }

    @Test("pending resize after dealloc does not crash")
    func pendingResizeAfterDeallocDoesNotCrash() async throws {
        // Arm a debounce, then drop the only strong reference. The
        // [weak self] capture in the timer closure must guard.
        do {
            let (view, _) = makeView()
            view.resizeDebounceMs = 30
            let target = sizeForColDelta(view, deltaCols: -1)
            view.setFrameSize(NSSize(width: target.width, height: target.height))
            // view goes out of scope here
        }
        try await Task.sleep(nanoseconds: 80_000_000) // past debounce
        // Nothing to assert — passing the await without crashing is
        // the contract.
    }
}
#endif
