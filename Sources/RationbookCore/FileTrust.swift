// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// Filesystem authorization includes ACLs as well as Unix permission bits.
enum FileTrust {
    static func rejectMutationACL(_ url: URL) throws {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT for an existing file with no extended ACL.
            if errno == ENOENT {
                var status = stat()
                if lstat(url.path, &status) == 0 { return }
            }
            throw RationbookPathError.unsafePath(url.path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var selector = ACL_FIRST_ENTRY
        while acl_get_entry(acl, selector.rawValue, &entry) == 0 {
            selector = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset(entry, &permissions) == 0 else {
                throw RationbookPathError.unsafePath(url.path)
            }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            // Conservatively reject mutation grants, including inherited grants.
            // Read-only and deny entries (including macOS home defaults) are safe.
            for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                               ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                guard acl_get_perm_np(permissions, permission) == 0 else {
                    throw RationbookPathError.unsafePath(url.path)
                }
            }
        }
    }

    /// Validate each newly materialized component before creating descendants.
    /// In a shared sticky directory, a racing foreign-owned entry must never
    /// become the parent of a directory that we subsequently accept as private.
    static func createDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            try validateDirectoryChain(url, requireExisting: true)
            return
        }
        guard errno == ENOENT else { throw RationbookPathError.unsafePath(url.path) }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { throw RationbookPathError.unsafePath(url.path) }
        try createDirectory(parent)
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
            throw RationbookPathError.unsafePath(url.path)
        }
        try validateDirectoryChain(url, requireExisting: true)
    }

    /// Checks existing ancestors before creation and again before using a path.
    /// Root-owned sticky temporary directories cannot replace an owned child.
    static func validateDirectoryChain(_ url: URL, requireExisting: Bool = false) throws {
        var current = url
        while true {
            var status = stat()
            if lstat(current.path, &status) == 0 {
                if status.st_mode & S_IFMT == S_IFLNK, status.st_uid == 0,
                   ["/var", "/tmp", "/etc"].contains(current.path) {
                    current = URL(fileURLWithPath: "/private" + current.path, isDirectory: true)
                    continue
                }
                let stickySystemDirectory = status.st_uid == 0 && status.st_mode & S_ISVTX != 0
                guard status.st_mode & S_IFMT == S_IFDIR,
                      status.st_uid == 0 || status.st_uid == geteuid(),
                      status.st_mode & 0o022 == 0 || stickySystemDirectory else {
                    throw RationbookPathError.unsafePath(current.path)
                }
                try rejectMutationACL(current)
            } else if requireExisting || errno != ENOENT {
                throw RationbookPathError.unsafePath(current.path)
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }
}
