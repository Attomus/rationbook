// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import RationbookCore

private func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

private let runningHelper = canonical(Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
private let explicitRoot: URL? = {
    guard [3, 4, 5].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--data-root" else { return nil }
    return canonical(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
}()
private let derivedRoot: URL? = {
    let bin = runningHelper.deletingLastPathComponent()
    guard bin.lastPathComponent == "bin" else { return nil }
    return bin.deletingLastPathComponent()
}()

let paths: RationbookPaths? = (explicitRoot ?? derivedRoot).map { RationbookPaths(root: $0) }
let authenticatedRecord: ClaudeIntegrationRecord? = {
    guard let paths,
          let installedRoot = derivedRoot,
          installedRoot == paths.root,
          explicitRoot == nil || explicitRoot == paths.root,
          (try? paths.prepare()) != nil,
          (try? paths.validateFileForRead(paths.claudeIntegration)) != nil,
          let data = try? Data(contentsOf: paths.claudeIntegration, options: [.mappedIfSafe]),
          let record = try? RationbookJSON.decoder().decode(ClaudeIntegrationRecord.self, from: data),
          canonical(URL(fileURLWithPath: record.helperPath)) == runningHelper,
          record.schemaVersion == 3,
          canonical(URL(fileURLWithPath: record.canonicalRootPath)) == paths.root,
          let helperData = try? Data(contentsOf: runningHelper, options: [.mappedIfSafe]),
          FileDigest.sha256(helperData) == record.helperSha256 else { return nil }
    return record
}()

if [4, 5].contains(CommandLine.arguments.count), ["--refresh", "--login"].contains(CommandLine.arguments[3]) {
    guard let paths, authenticatedRecord != nil else { exit(70) }
    let sessionID = CommandLine.arguments.count == 5 ? UUID(uuidString: CommandLine.arguments[4]) : nil
    guard CommandLine.arguments.count == 4 || sessionID != nil else { exit(64) }
    do { try ClaudeIntegrationManager(paths: paths).runUsageSession(sessionID: sessionID, signIn: CommandLine.arguments[3] == "--login") }
    catch {
        FileHandle.standardError.write(Data("Rationbook: \(error.localizedDescription)\n".utf8))
        exit(70)
    }
}

let previousCommand: String? = authenticatedRecord?.previousStatusLine
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["command"] as? String

// Shell forwarding is deliberately downstream of manifest/root/helper
// authentication. A copied helper or a root-drifted invocation cannot execute
// the user's previous status-line command.
let process: Process? = previousCommand.flatMap { command in
    guard !command.isEmpty else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let input = Pipe()
    // A status-line command may exit without reading. Keep its broken pipe
    // from terminating this helper before the quota observation is persisted.
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return nil }
    process.standardInput = input
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do { try process.run(); return process } catch { return nil }
}

var parseBuffer = Data()
var exceededParseLimit = false
while let chunk = try? FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
    if !exceededParseLimit {
        if parseBuffer.count + chunk.count <= 1_048_576 {
            parseBuffer.append(chunk)
        } else {
            exceededParseLimit = true
            parseBuffer.removeAll(keepingCapacity: false)
        }
    }
    if let pipe = process?.standardInput as? Pipe { try? pipe.fileHandleForWriting.write(contentsOf: chunk) }
}
if let pipe = process?.standardInput as? Pipe { try? pipe.fileHandleForWriting.close() }

let observation = exceededParseLimit ? nil : try? ClaudeAdapter.observation(fromStatusLine: parseBuffer)
if let paths, authenticatedRecord != nil, let observation {
    try? ClaudeAdapter.persist(observation, paths: paths)
}

if let process {
    process.waitUntilExit()
    exit(process.terminationStatus)
}

if let observation {
    var parts: [String] = []
    if let value = observation.rateLimits.fiveHour { parts.append(String(format: "5h %.0f%% remaining", max(0, 100 - value.usedPercentage))) }
    if let value = observation.rateLimits.sevenDay { parts.append(String(format: "7d %.0f%% remaining", max(0, 100 - value.usedPercentage))) }
    print(parts.isEmpty ? "Rationbook: waiting for aggregate quota" : "Rationbook: " + parts.joined(separator: " · "))
}
exit(0)
