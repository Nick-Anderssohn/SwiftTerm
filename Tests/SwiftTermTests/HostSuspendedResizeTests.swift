//
//  HostSuspendedResizeTests.swift
//
//  Pins the contract that `TerminalView.hostSuspendsResize` lets an
//  embedding host completely defer the `terminal.resize` apply (and
//  the downstream TIOCSWINSZ ioctl) for the duration of a user gesture
//  — window live-resize, custom split-pane drag, etc. — so SIGWINCH
//  fires exactly once on gesture end.
//
//  This is the principled "wait for mouse-up" path. The 200 ms
//  `resizeDebounceMs` coalescer (covered by ResizeCoalescingTests) is
//  a heuristic time window that doesn't fully close the SIGWINCH-vs-
//  shell-redraw race; a host-driven gesture gate does, by collapsing
//  every resize during the gesture into one apply at gesture end.
//
//  Invariants pinned here:
//   - while suspended, no apply runs (and no coalescer timer is armed)
//   - flipping suspension off applies exactly once at the live frame
//   - flushing with no pending resize is a no-op
//   - a coalescer timer in flight when suspension starts must NOT
//     apply mid-gesture (the timer-callback re-check)
//   - idempotent toggles do not double-flush
//

#if os(macOS)
import Foundation
import Testing
import AppKit

@testable import SwiftTerm

@MainActor
@Suite("Host-suspended resize")
final class HostSuspendedResizeTests {

    /// Shape-compatible with ResizeCoalescingTests.RecordingDelegate
    /// — kept private here so the two suites stay independent.
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

    private func makeView(initialSize: CGSize = CGSize(width: 800, height: 600)) -> (TerminalView, RecordingDelegate) {
        let view = TerminalView(frame: CGRect(origin: .zero, size: initialSize), font: nil)
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate
        return (view, delegate)
    }

    /// Mirrors ResizeCoalescingTests.sizeForColDelta — picks a target
    /// pixel size that lands at a strictly different `(cols, rows)`
    /// than the current grid, so applies aren't masked by the
    /// "no-change" early-return inside applySizeChange.
    private func sizeForColDelta(_ view: TerminalView, deltaCols: Int) -> CGSize {
        let cellW = view.cellDimension.width
        let cellH = view.cellDimension.height
        let curCols = view.terminal.cols
        let targetCols = max(1, curCols + deltaCols)
        let width = CGFloat(targetCols + 1) * cellW
        let height = CGFloat(view.terminal.rows) * cellH
        return CGSize(width: width, height: height)
    }

    @Test("burst of resizes while suspended produces zero applies")
    func suspendedBurstProducesZeroApplies() async throws {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30
        view.hostSuspendsResize = true

        // Five distinct sizes during a "drag". With suspension on,
        // none should reach the delegate, even after the debounce
        // window would have elapsed.
        for delta in [-1, -2, -3, -4, -5] {
            let target = sizeForColDelta(view, deltaCols: delta)
            view.setFrameSize(NSSize(width: target.width, height: target.height))
        }
        try await Task.sleep(nanoseconds: 60_000_000) // past debounce

        #expect(delegate.sizeChangedCalls.isEmpty,
                "suspended resizes must not fan out, got \(delegate.sizeChangedCalls.count)")
    }

    @Test("flipping suspension off applies exactly once at the latest size")
    func suspensionEndAppliesOnce() async throws {
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30
        view.hostSuspendsResize = true

        for delta in [-1, -2, -3] {
            let target = sizeForColDelta(view, deltaCols: delta)
            view.setFrameSize(NSSize(width: target.width, height: target.height))
        }
        let final = sizeForColDelta(view, deltaCols: -7)
        view.setFrameSize(NSSize(width: final.width, height: final.height))

        // Release the gesture.
        view.hostSuspendsResize = false

        // The flush is synchronous from didSet; no sleep needed.
        #expect(delegate.sizeChangedCalls.count == 1,
                "expected exactly one apply on flush, got \(delegate.sizeChangedCalls.count)")
        // The applied geometry must match the post-apply core state
        // — i.e. the flush re-read frame.size, didn't replay an old
        // captured value.
        let recorded = delegate.sizeChangedCalls.last!
        #expect(recorded.cols == view.terminal.cols)
        #expect(recorded.rows == view.terminal.rows)
    }

    @Test("flipping suspension off with no pending resize is a no-op")
    func suspensionEndWithNoPendingDoesNothing() {
        let (view, delegate) = makeView()
        view.hostSuspendsResize = true
        view.hostSuspendsResize = false
        #expect(delegate.sizeChangedCalls.isEmpty,
                "no pending resize → no flush, got \(delegate.sizeChangedCalls.count)")
    }

    @Test("a coalescer timer that fires mid-suspension does not apply")
    func midCoalesceSuspensionDeflectsApply() async throws {
        // This is the timer-callback re-check test. Without the
        // re-check inside processSizeChange's asyncAfter closure,
        // a timer scheduled before the user grabs the window edge
        // would fire mid-gesture and apply the suspended resize.
        let (view, delegate) = makeView()
        view.resizeDebounceMs = 30

        // Arm a coalescer apply (no suspension yet).
        let target = sizeForColDelta(view, deltaCols: -1)
        view.setFrameSize(NSSize(width: target.width, height: target.height))

        // User grabs the window edge before the timer fires.
        view.hostSuspendsResize = true

        // Wait past the debounce — the timer fires, sees the
        // suspension flag, and must NOT apply.
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(delegate.sizeChangedCalls.isEmpty,
                "timer that fires while suspended must not apply, got \(delegate.sizeChangedCalls.count)")

        // User releases. Flush applies the resize once.
        view.hostSuspendsResize = false
        #expect(delegate.sizeChangedCalls.count == 1,
                "expected one apply on flush, got \(delegate.sizeChangedCalls.count)")
    }

    @Test("idempotent suspension toggles do not double-flush")
    func idempotentTogglesNoDoubleFlush() {
        let (view, delegate) = makeView()
        let target = sizeForColDelta(view, deltaCols: -1)
        view.hostSuspendsResize = true
        view.setFrameSize(NSSize(width: target.width, height: target.height))

        // Setting true again is a no-op (no oldValue→newValue
        // transition into the unsuspended state).
        view.hostSuspendsResize = true
        #expect(delegate.sizeChangedCalls.isEmpty)

        // First true→false fires the flush.
        view.hostSuspendsResize = false
        let afterFirstFlush = delegate.sizeChangedCalls.count
        #expect(afterFirstFlush == 1)

        // Second false→false is a no-op (oldValue is also false).
        view.hostSuspendsResize = false
        #expect(delegate.sizeChangedCalls.count == afterFirstFlush,
                "redundant toggle must not re-fire, got \(delegate.sizeChangedCalls.count)")
    }
}
#endif
