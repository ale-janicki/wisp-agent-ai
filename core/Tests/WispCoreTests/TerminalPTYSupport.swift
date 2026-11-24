import Darwin
import Foundation

/// A real child on a real pty, spawned with posix_spawn (a new session whose controlling terminal is the pty), for tests of what
/// a terminal session depends on: the login shell's PATH, the exit status, the window size reaching the child.
final class TestPTY {
    private let master: Int32
    private let pid: pid_t
    private var finished: Int32?

    init(executable: String, argv: [String], env: [String: String], directory: String, columns: Int = 80, rows: Int = 24) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        var nameBuffer = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &nameBuffer, nil, &window) == 0 else { throw TestPTYError.openpty(errno) }
        // The slave stays open until the child has opened it: the window size lives with an open tty.
        defer { close(slave) }
        let slavePath = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addclose(&actions, master)
        // Opening the tty as the session leader makes it the controlling terminal.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argvPointers = argv.map { strdup($0) } + [nil]
        let envPointers = env.keys.sorted().map { strdup("\($0)=\(env[$0] ?? "")") } + [nil]
        defer {
            argvPointers.forEach { free($0) }
            envPointers.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argvPointers, envPointers)
        guard status == 0 else {
            close(master)
            throw TestPTYError.spawn(status)
        }
        self.master = master
        pid = child
    }

    deinit {
        if finished == nil {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        close(master)
    }

    /// Everything the child writes until `marker` shows up, or until it ends or `timeout` passes.
    func read(until marker: String? = nil, timeout: TimeInterval = 10) -> String {
        var collected = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready > 0 {
                let count = Darwin.read(master, &buffer, buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf: buffer[0..<count])
                if let marker, String(decoding: collected, as: UTF8.self).contains(marker) { break }
            }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    /// The pty's new size; the kernel signals the child's foreground group with SIGWINCH.
    func resize(columns: Int, rows: Int) {
        var window = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &window)
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        _ = Darwin.write(master, bytes, bytes.count)
    }

    /// The exit status, or nil if the child is still running after `timeout`.
    func waitForExit(timeout: TimeInterval = 10) -> Int32? {
        if let finished { return finished }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
                finished = code
                return code
            }
            usleep(20_000)
        }
        return nil
    }
}

enum TestPTYError: Error {
    case openpty(Int32)
    case spawn(Int32)
}
