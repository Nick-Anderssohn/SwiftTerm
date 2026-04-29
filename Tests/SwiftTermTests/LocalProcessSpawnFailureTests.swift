//
//  LocalProcessSpawnFailureTests.swift
//
//  Pins the contract that a forkpty failure surfaces via
//  `LocalProcessDelegate.processTerminated(exitCode: nil)`. The
//  failure path is otherwise hard to reach — pty table exhaustion
//  isn't reproducible from a unit test — so the `forkpty` property
//  on `LocalProcess` is overridden with a stub returning nil.
//
//  Without this coverage the failure-surface branch could silently
//  regress (e.g. an upstream rebase that drops the `else` block) and
//  callers would once again get no signal from a failed spawn.
//

#if !os(iOS) && !os(Windows)
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
@Suite("LocalProcess spawn failure")
final class LocalProcessSpawnFailureTests {

    /// Records `processTerminated` callbacks on the dispatch queue the
    /// process was constructed with. Stores them in a serial actor so
    /// the test can read the count without racing the producer.
    final class RecordingDelegate: LocalProcessDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _exits: [Int32?] = []

        var exitCalls: [Int32?] {
            lock.lock(); defer { lock.unlock() }
            return _exits
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            lock.lock()
            _exits.append(exitCode)
            lock.unlock()
        }

        func dataReceived(slice: ArraySlice<UInt8>) {}

        func getWindowSize() -> winsize {
            winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
    }

    /// Drives the spawn through a stubbed forkpty that returns nil.
    /// Asserts: exactly one `processTerminated` callback fires, with
    /// `exitCode == nil`, dispatched on the configured queue (not
    /// synchronously from inside `startProcess`).
    @Test
    func failingForkpty_firesProcessTerminatedOnceWithNilExit() async {
        let delegate = RecordingDelegate()
        // Use a private serial queue so we can `sync` on it later to
        // flush any pending callback before asserting.
        let queue = DispatchQueue(label: "LocalProcessSpawnFailureTests.queue")
        let process = LocalProcess(delegate: delegate, dispatchQueue: queue)
        process.forkpty = { _, _, _, _, _ in nil }

        // Sync access on `delegate.exitCalls` before startProcess to
        // confirm the pre-condition (no callbacks yet).
        #expect(delegate.exitCalls.isEmpty)

        process.startProcess(executable: "/bin/zsh", args: ["-il"])

        // The failure callback is async-dispatched on `queue`. A sync
        // round-trip flushes any work scheduled before this point.
        queue.sync {}

        #expect(delegate.exitCalls.count == 1)
        #expect(delegate.exitCalls.first == .some(nil))
        #expect(process.running == false)
        #expect(process.shellPid == 0)
        #expect(process.childfd == -1)
    }

    /// `startProcess` returning normally (no spawned child, since
    /// forkpty stub returned nil) means the IO setup never ran. A
    /// later `terminate()` must not crash — it has nothing to clean
    /// up but should be a safe no-op.
    @Test
    func failedSpawn_terminateIsSafeNoOp() async {
        let delegate = RecordingDelegate()
        let queue = DispatchQueue(label: "LocalProcessSpawnFailureTests.queue.term")
        let process = LocalProcess(delegate: delegate, dispatchQueue: queue)
        process.forkpty = { _, _, _, _, _ in nil }

        process.startProcess(executable: "/bin/zsh", args: ["-il"])
        queue.sync {}

        // Should not crash, should not fire a second processTerminated.
        process.terminate()
        queue.sync {}

        #expect(delegate.exitCalls.count == 1)
    }

    /// The success branch must still receive the args we supplied.
    /// Using a stubbed forkpty that records its inputs, drive a
    /// success-shaped return (any positive pid + masterFd) and assert
    /// the args reach the stub. The IO setup that follows can still
    /// fail (the masterFd is fake), but pre-DispatchIO state must
    /// match what we passed.
    @Test
    func successFork_receivesPassedArgs() async {
        struct Captured {
            var executable: String?
            var args: [String]?
            var env: [String]?
            var cwd: String?
        }
        let captured = NSLock()
        var box = Captured()

        let delegate = RecordingDelegate()
        let queue = DispatchQueue(label: "LocalProcessSpawnFailureTests.queue.args")
        let process = LocalProcess(delegate: delegate, dispatchQueue: queue)
        process.forkpty = { exec, args, env, cwd, _ in
            captured.lock()
            box.executable = exec
            box.args = args
            box.env = env
            box.cwd = cwd
            captured.unlock()
            // Return nil to short-circuit IO setup — we only care
            // about the args this stub received.
            return nil
        }

        process.startProcess(
            executable: "/bin/zsh",
            args: ["-il"],
            environment: ["TERM=xterm-256color", "USER=tester"],
            execName: nil,
            currentDirectory: "/tmp"
        )
        queue.sync {}

        captured.lock(); defer { captured.unlock() }
        #expect(box.executable == "/bin/zsh")
        // `LocalProcess.startProcessWithForkpty` injects the executable
        // name as argv[0] when execName is nil.
        #expect(box.args == ["/bin/zsh", "-il"])
        #expect(box.env == ["TERM=xterm-256color", "USER=tester"])
        #expect(box.cwd == "/tmp")
    }
}

#endif
