// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

public final class ManagedChildProcess: @unchecked Sendable {
    public let standardInput: FileHandle
    public let standardOutput: FileHandle
    public let standardError: FileHandle

    private let processIdentifier: pid_t
    private let preparedExecutable: PreparedExecutableLaunch
    private let reapLock = NSLock()
    private let statusLock = NSLock()
    private let cleanupLock = NSLock()
    private var waitStatus: Int32?
    private var processGroupClosed = false

    public init(executable: URL, arguments: [String], terminal: Bool = false) throws {
        let preparedExecutable = try ExecutableLocator.prepareForLaunch(executable)
        var launchSucceeded = false
        defer {
            if !launchSucceeded { preparedExecutable.cleanup() }
        }
        self.preparedExecutable = preparedExecutable
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw ProcessRunnerError.failed(executable.lastPathComponent, -1, "Could not initialize process controls.")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let inputRead = input.fileHandleForReading.fileDescriptor
        let inputWrite = input.fileHandleForWriting.fileDescriptor
        let outputRead = output.fileHandleForReading.fileDescriptor
        let outputWrite = output.fileHandleForWriting.fileDescriptor
        let errorRead = error.fileHandleForReading.fileDescriptor
        let errorWrite = error.fileHandleForWriting.fileDescriptor

        for descriptor in [inputRead, inputWrite, outputRead, outputWrite, errorRead, errorWrite] {
            let descriptorFlags = fcntl(descriptor, F_GETFD)
            guard descriptorFlags >= 0,
                  fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                throw ProcessRunnerError.failed(
                    executable.lastPathComponent,
                    -1,
                    "Could not isolate provider pipe descriptors."
                )
            }
        }
        guard fcntl(inputWrite, F_SETNOSIGPIPE, 1) == 0 else {
            throw ProcessRunnerError.failed(executable.lastPathComponent, -1, "Could not configure the provider input pipe.")
        }

        var terminalMaster: Int32 = -1
        var terminalSlave: Int32 = -1
        defer {
            if terminalMaster >= 0 { close(terminalMaster) }
            if terminalSlave >= 0 { close(terminalSlave) }
        }
        if terminal {
            var name = [CChar](repeating: 0, count: 128)
            var size = winsize(ws_row: 32, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&terminalMaster, &terminalSlave, &name, nil, &size) == 0 else {
                throw ProcessRunnerError.invalidOutput("Could not create Claude usage terminal.")
            }
            guard fcntl(terminalMaster, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(terminalSlave, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ProcessRunnerError.invalidOutput("Could not isolate terminal descriptors.")
            }
            // Open the slave after setsid so it becomes the child's controlling terminal.
            guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0,
                  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, name, O_RDWR, 0) == 0,
                  posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0 else {
                throw ProcessRunnerError.invalidOutput("Could not configure Claude usage terminal.")
            }
        } else {
            posix_spawn_file_actions_adddup2(&actions, inputRead, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO)
            for descriptor in [inputWrite, outputRead, errorRead] {
                posix_spawn_file_actions_addclose(&actions, descriptor)
            }
            for (descriptor, standard) in [(inputRead, STDIN_FILENO), (outputWrite, STDOUT_FILENO), (errorWrite, STDERR_FILENO)]
            where descriptor != standard {
                posix_spawn_file_actions_addclose(&actions, descriptor)
            }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
        }

        let argvStrings = [executable.path] + arguments
        let environmentStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var spawnedPID: pid_t = 0
        let result = Self.withCStringArray(argvStrings) { argv in
            Self.withCStringArray(environmentStrings) { environment in
                posix_spawn(&spawnedPID, preparedExecutable.executableURL.path, &actions, &attributes, argv, environment)
            }
        }
        guard result == 0 else {
            throw ProcessRunnerError.failed(
                executable.lastPathComponent,
                Int32(result),
                String(cString: strerror(result))
            )
        }

        processIdentifier = spawnedPID
        if terminal {
            let writer = dup(terminalMaster)
            guard writer >= 0, fcntl(writer, F_SETFD, FD_CLOEXEC) == 0 else {
                if writer >= 0 { close(writer) }
                _ = kill(-spawnedPID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(spawnedPID, &status, 0)
                throw ProcessRunnerError.invalidOutput("Could not create terminal input.")
            }
            standardInput = FileHandle(fileDescriptor: writer, closeOnDealloc: true)
            standardOutput = FileHandle(fileDescriptor: terminalMaster, closeOnDealloc: true)
            terminalMaster = -1
        } else {
            standardInput = input.fileHandleForWriting
            standardOutput = output.fileHandleForReading
        }
        standardError = error.fileHandleForReading
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        launchSucceeded = true
    }

    public func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !reap(noHang: true) {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        closeProcessGroup(gracePeriod: 0.1)
        preparedExecutable.cleanup()
        return true
    }

    public func terminateAndReap(gracePeriod: TimeInterval = 1) {
        closeProcessGroup(gracePeriod: gracePeriod)
        _ = reap(noHang: false)
        preparedExecutable.cleanup()
    }

    public var exitCode: Int32 {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard let status = waitStatus else { return -1 }
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }

    /// Reaping happens on the caller rather than a shared dispatch queue. That
    /// avoids thread-pool starvation when several synchronous provider calls
    /// reach their lifecycle boundary at once.
    private func reap(noHang: Bool) -> Bool {
        statusLock.lock()
        let alreadyReaped = waitStatus != nil
        statusLock.unlock()
        if alreadyReaped { return true }

        reapLock.lock()
        defer { reapLock.unlock() }
        statusLock.lock()
        let reapedWhileWaiting = waitStatus != nil
        statusLock.unlock()
        if reapedWhileWaiting { return true }

        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, noHang ? WNOHANG : 0)
        } while result == -1 && errno == EINTR
        guard result == processIdentifier else { return false }

        statusLock.lock()
        waitStatus = status
        statusLock.unlock()
        return true
    }

    private func closeProcessGroup(gracePeriod: TimeInterval) {
        cleanupLock.lock()
        guard !processGroupClosed else {
            cleanupLock.unlock()
            return
        }
        processGroupClosed = true
        cleanupLock.unlock()

        guard processGroupExists() else { return }
        _ = kill(-processIdentifier, SIGTERM)
        let deadline = Date().addingTimeInterval(gracePeriod)
        while processGroupExists(), Date() < deadline {
            usleep(10_000)
        }
        if processGroupExists() {
            _ = kill(-processIdentifier, SIGKILL)
        }
    }

    private func processGroupExists() -> Bool {
        if kill(-processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.dropLast().forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
