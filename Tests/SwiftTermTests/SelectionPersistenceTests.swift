//
//  SelectionPersistenceTests.swift
//  SwiftTermTests
//
//  Verifies that an active text selection survives streaming
//  output, and that selection row indices are translated when
//  scrollback eviction shifts the buffer's logical origin.
//

import Foundation
import Testing

#if canImport(AppKit) || canImport(UIKit)
import CoreGraphics
#endif

@testable import SwiftTerm

final class SelectionPersistenceTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    // MARK: - View-layer: feed / linefeed must not clear selection

#if canImport(AppKit) || canImport(UIKit)
    @Test func feedDoesNotClearActiveSelectionWhenMouseReportingOff() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        view.allowMouseReporting = false
        view.terminal.feed(text: "hello world")
        view.selection.setSelection(start: Position(col: 0, row: 0),
                                    end: Position(col: 5, row: 0))
        #expect(view.selection.active)
        let originalStart = view.selection.start
        let originalEnd = view.selection.end

        // Stream more bytes without newlines.
        view.feed(byteArray: ArraySlice("more bytes ".utf8))

        #expect(view.selection.active)
        #expect(view.selection.start == originalStart)
        #expect(view.selection.end == originalEnd)
    }

    @Test func feedDoesNotClearActiveSelectionWhenMouseReportingOn() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        view.allowMouseReporting = true
        view.terminal.feed(text: "hello world")
        view.selection.setSelection(start: Position(col: 0, row: 0),
                                    end: Position(col: 5, row: 0))
        #expect(view.selection.active)
        let originalStart = view.selection.start
        let originalEnd = view.selection.end

        view.feed(byteArray: ArraySlice("more bytes ".utf8))

        #expect(view.selection.active)
        #expect(view.selection.start == originalStart)
        #expect(view.selection.end == originalEnd)
    }

    @Test func linefeedDoesNotClearSelection() {
        let view = TerminalView(frame: CGRect(origin: .zero, size: .init(width: 400, height: 100)))
        view.allowMouseReporting = true
        view.terminal.feed(text: "hello")
        view.selection.setSelection(start: Position(col: 0, row: 0),
                                    end: Position(col: 4, row: 0))
        let originalStart = view.selection.start
        let originalEnd = view.selection.end

        // Trigger several linefeed delegate callbacks via the parser.
        view.terminal.feed(text: "a\nb\nc\n")

        #expect(view.selection.active)
        #expect(view.selection.start == originalStart)
        #expect(view.selection.end == originalEnd)
    }
#endif

    // MARK: - Core: scrollback eviction translates selection rows

    /// Fill the buffer to exactly `maxLength` lines without
    /// triggering any eviction. Stops as soon as the buffer is full.
    private func fillToCapacity(_ terminal: Terminal) {
        let maxLength = terminal.buffer.lines.maxLength
        while terminal.buffer.lines.count < maxLength {
            terminal.feed(text: "X\n")
        }
    }

    @Test func scrollbackEvictionTranslatesSelectionRows() {
        let terminal = Terminal(delegate: self,
                                options: TerminalOptions(cols: 20, rows: 5, scrollback: 10))
        let selection = SelectionService(terminal: terminal)

        fillToCapacity(terminal)

        // Place a selection well inside the scrollback region.
        selection.setSelection(start: Position(col: 0, row: 5),
                               end: Position(col: 1, row: 7))
        #expect(selection.active)

        // Trigger 3 evictions.
        for _ in 0..<3 {
            terminal.feed(text: "X\n")
        }

        #expect(selection.active)
        #expect(selection.start.row == 2)
        #expect(selection.end.row == 4)
        #expect(selection.start.col == 0)
        #expect(selection.end.col == 1)
    }

    @Test func scrollbackEvictionClearsSelectionWhenFullyOffTop() {
        let terminal = Terminal(delegate: self,
                                options: TerminalOptions(cols: 20, rows: 5, scrollback: 10))
        let selection = SelectionService(terminal: terminal)

        fillToCapacity(terminal)

        // Selection spans rows 0-1 — both go negative after 5 evictions.
        selection.setSelection(start: Position(col: 0, row: 0),
                               end: Position(col: 5, row: 1))
        #expect(selection.active)

        for _ in 0..<5 {
            terminal.feed(text: "X\n")
        }

        #expect(!selection.active)
    }

    @Test func scrollbackEvictionClampsStraddlingSelection() {
        let terminal = Terminal(delegate: self,
                                options: TerminalOptions(cols: 20, rows: 5, scrollback: 10))
        let selection = SelectionService(terminal: terminal)

        fillToCapacity(terminal)

        // Start row goes negative (-3), end row stays positive (2).
        selection.setSelection(start: Position(col: 0, row: 0),
                               end: Position(col: 5, row: 5))
        #expect(selection.active)

        for _ in 0..<3 {
            terminal.feed(text: "X\n")
        }

        #expect(selection.active)
        #expect(selection.start.row == 0)
        #expect(selection.start.col == 0)
        #expect(selection.end.row == 2)
        #expect(selection.end.col == 5)
    }
}
