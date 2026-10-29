// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

public final class ProviderRefreshLock: @unchecked Sendable {
    private var descriptor: Int32 = -1

    public init?(provider: String, paths: RationbookPaths, wait: Bool = false) {
        guard !provider.isEmpty,
              provider.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                      ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
              }),
              (try? paths.prepare()) != nil else { return nil }
        let url = paths.locksDirectory.appendingPathComponent("\(provider).lock")
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        var status = stat()
        guard descriptor >= 0,
              fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            descriptor = -1
            return nil
        }
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
