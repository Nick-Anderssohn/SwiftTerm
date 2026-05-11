//
//  ScrollPhaseTests.swift
//
//  Pins the contract of `TerminalView.shouldDropRubberBand`: a pure
//  gesture-state machine that filters macOS trackpad rubber-band
//  snap-back events out of the `scrollWheel(with:)` pipeline while
//  preserving normal inertial momentum and leaving mouse-wheel
//  events untouched.
//
//  Background: macOS trackpad gestures emit reverse-sign deltas at
//  scroll boundaries (the "rubber-band" snap-back). Feeding those
//  into `scroll(byPoints:)` causes the viewport to bounce back down
//  after the user scrolls to the top of scrollback — visible in
//  Nice when running `git log` and scrolling up. The helper under
//  test latches the user-driven direction on each gesture and drops
//  momentum-phase deltas whose sign opposes the latch.
//
//  Sequences here represent the actual stream macOS delivers across
//  a complete gesture: `.began` → `.changed` ×N → `.ended` →
//  `momentum.began` → `momentum.changed` ×M → `momentum.ended`. The
//  helper is pure / static, so no `NSEvent` synthesis is needed.
//

#if os(macOS)
import Foundation
import Testing
import AppKit

@testable import SwiftTerm

@MainActor
@Suite("Scroll-wheel phase filter")
final class ScrollPhaseTests {

    /// Sugar: one frame of a gesture.
    struct Frame {
        let phase: NSEvent.Phase
        let momentum: NSEvent.Phase
        let deltaY: CGFloat
    }

    /// Run a sequence of frames through `shouldDropRubberBand` and
    /// return the per-frame drop verdicts plus the final state.
    private func run(_ frames: [Frame])
        -> (dropped: [Bool],
            latch: TerminalView.ScrollGestureDirection?,
            accumulator: CGFloat)
    {
        var latch: TerminalView.ScrollGestureDirection? = nil
        var accumulator: CGFloat = 0
        var dropped: [Bool] = []
        for f in frames {
            let drop = TerminalView.shouldDropRubberBand(
                phase: f.phase,
                momentum: f.momentum,
                deltaY: f.deltaY,
                latch: &latch,
                accumulator: &accumulator)
            dropped.append(drop)
        }
        return (dropped, latch, accumulator)
    }

    @Test("pure user-driven upward swipe drops nothing and latches .up")
    func userDrivenUpwardLatchesUp() {
        let seq: [Frame] = [
            Frame(phase: .began,   momentum: [], deltaY:  4),
            Frame(phase: .changed, momentum: [], deltaY:  6),
            Frame(phase: .changed, momentum: [], deltaY:  8),
            Frame(phase: .changed, momentum: [], deltaY:  3),
        ]
        let (dropped, latch, _) = run(seq)
        #expect(dropped == [false, false, false, false])
        #expect(latch == .up)
    }

    @Test("clean upward gesture + matching momentum drops nothing; latch clears on momentum end")
    func cleanGestureAndMomentum() {
        let seq: [Frame] = [
            Frame(phase: .began,    momentum: [],          deltaY:  4),
            Frame(phase: .changed,  momentum: [],          deltaY:  6),
            Frame(phase: .changed,  momentum: [],          deltaY:  8),
            Frame(phase: .ended,    momentum: [],          deltaY:  0),
            Frame(phase: [],        momentum: .began,      deltaY:  5),
            Frame(phase: [],        momentum: .changed,    deltaY:  4),
            Frame(phase: [],        momentum: .changed,    deltaY:  2),
            Frame(phase: [],        momentum: .ended,      deltaY:  0),
        ]
        let (dropped, latch, accumulator) = run(seq)
        #expect(dropped == Array(repeating: false, count: seq.count))
        #expect(latch == nil)
        #expect(accumulator == 0)
    }

    @Test("rubber-band reverse-sign frame inside momentum is dropped; siblings keep")
    func rubberBandReverseFrameDropped() {
        let seq: [Frame] = [
            Frame(phase: .began,   momentum: [],       deltaY:  4),
            Frame(phase: .changed, momentum: [],       deltaY:  6),
            Frame(phase: .ended,   momentum: [],       deltaY:  0),
            Frame(phase: [],       momentum: .began,   deltaY:  3),
            Frame(phase: [],       momentum: .changed, deltaY:  2),
            // The snap-back: opposite sign to the latched .up.
            Frame(phase: [],       momentum: .changed, deltaY: -1),
            Frame(phase: [],       momentum: .changed, deltaY: -2),
            Frame(phase: [],       momentum: .ended,   deltaY:  0),
        ]
        let (dropped, latch, _) = run(seq)
        #expect(dropped == [
            false, false, false,   // user-driven phase
            false, false,           // matching momentum
            true,  true,            // rubber-band frames dropped
            false                   // .ended always passes through
        ])
        #expect(latch == nil) // momentum.ended cleared the latch
    }

    @Test("mouse-wheel events (empty phase + empty momentum) always pass and never set the latch")
    func mouseWheelPassesAndNeverLatches() {
        let seq: [Frame] = [
            Frame(phase: [], momentum: [], deltaY:  3),
            Frame(phase: [], momentum: [], deltaY:  2),
            Frame(phase: [], momentum: [], deltaY: -1),  // a real reverse — still a wheel click
            Frame(phase: [], momentum: [], deltaY:  4),
        ]
        let (dropped, latch, accumulator) = run(seq)
        #expect(dropped == [false, false, false, false])
        #expect(latch == nil)
        #expect(accumulator == 0)
    }

    @Test("mid-gesture genuine reversal re-latches direction and zeros the accumulator")
    func midGestureReversalReLatches() {
        // Prime the accumulator manually so we can observe the reset
        // on direction flip. (The helper itself only mutates the
        // accumulator on `.began` / momentum.end / user-driven flip.)
        var latch: TerminalView.ScrollGestureDirection? = nil
        var acc: CGFloat = 0
        let frames: [Frame] = [
            Frame(phase: .began,   momentum: [], deltaY:  5),
            Frame(phase: .changed, momentum: [], deltaY:  7),
        ]
        for f in frames {
            _ = TerminalView.shouldDropRubberBand(
                phase: f.phase, momentum: f.momentum, deltaY: f.deltaY,
                latch: &latch, accumulator: &acc)
        }
        // Simulate caller-side accumulation between events.
        acc = 12.5
        #expect(latch == .up)

        // First reverse-sign user-driven frame: should flip the
        // latch and zero the accumulator.
        let drop1 = TerminalView.shouldDropRubberBand(
            phase: .changed, momentum: [], deltaY: -3,
            latch: &latch, accumulator: &acc)
        #expect(drop1 == false)
        #expect(latch == .down)
        #expect(acc == 0)

        // Subsequent same-direction frame is a no-op for state.
        let drop2 = TerminalView.shouldDropRubberBand(
            phase: .changed, momentum: [], deltaY: -2,
            latch: &latch, accumulator: &acc)
        #expect(drop2 == false)
        #expect(latch == .down)
    }

    @Test("zero-delta momentum frame is dropped (no direction to infer)")
    func zeroDeltaMomentumDropped() {
        var latch: TerminalView.ScrollGestureDirection? = .up
        var acc: CGFloat = 0
        let drop = TerminalView.shouldDropRubberBand(
            phase: [], momentum: .changed, deltaY: 0,
            latch: &latch, accumulator: &acc)
        #expect(drop == true)
        // State preserved — the frame is a no-op.
        #expect(latch == .up)
        #expect(acc == 0)
    }

    @Test("momentum frame before any latch (no user-driven phase seen) passes through")
    func momentumWithoutLatchPasses() {
        // Gesture started before the view became first responder:
        // we see only the momentum tail. Without a latch we have no
        // basis to call any direction "wrong" — let it through.
        var latch: TerminalView.ScrollGestureDirection? = nil
        var acc: CGFloat = 0
        let drop = TerminalView.shouldDropRubberBand(
            phase: [], momentum: .changed, deltaY: -5,
            latch: &latch, accumulator: &acc)
        #expect(drop == false)
        #expect(latch == nil)
    }

    @Test("new gesture's .began resets stale latch and accumulator")
    func beganResetsStaleState() {
        var latch: TerminalView.ScrollGestureDirection? = .down
        var acc: CGFloat = 9.5
        // A new gesture starts. .began with a non-zero delta both
        // resets the prior state and latches the new direction.
        let drop = TerminalView.shouldDropRubberBand(
            phase: .began, momentum: [], deltaY: 3,
            latch: &latch, accumulator: &acc)
        #expect(drop == false)
        #expect(latch == .up)
        #expect(acc == 0)
    }

    @Test(".cancelled at user phase keeps latch; momentum .cancelled clears it")
    func cancelledSemantics() {
        var latch: TerminalView.ScrollGestureDirection? = nil
        var acc: CGFloat = 0
        // User-phase up, then user-phase .cancelled (gesture aborted
        // without lifting cleanly).
        _ = TerminalView.shouldDropRubberBand(
            phase: .began, momentum: [], deltaY: 4,
            latch: &latch, accumulator: &acc)
        _ = TerminalView.shouldDropRubberBand(
            phase: .cancelled, momentum: [], deltaY: 0,
            latch: &latch, accumulator: &acc)
        // Latch preserved so any straggler momentum can still be
        // filtered against it.
        #expect(latch == .up)

        // Now a momentum.cancelled — clears.
        _ = TerminalView.shouldDropRubberBand(
            phase: [], momentum: .cancelled, deltaY: 0,
            latch: &latch, accumulator: &acc)
        #expect(latch == nil)
        #expect(acc == 0)
    }
}

#endif
