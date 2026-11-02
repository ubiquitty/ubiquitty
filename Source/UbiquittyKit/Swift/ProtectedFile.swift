// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ProtectedFile.swift — Complete-protected file creation for the iOS PAL.
//
// SystemPAL's durable writer asks for its temporary file through
// `Platform::createCompleteProtectedFile` (Source/Platform/iOS/ProtectedFile.h),
// which resolves to the C symbol defined here. File protection classes are a
// Foundation contract, so the creation and the protection check live in Swift;
// the descriptor identity checks around them are POSIX and stay on the
// descriptors the caller pinned.

#if os(iOS)
import Darwin
import Foundation

private func isSameFile(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev && first.st_ino == second.st_ino
}

private func isDirectory(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFDIR
}

private func isRegularFile(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFREG
}

/// Whether `path` still opens the directory `expected` describes.
private func pathNamesDirectory(_ path: String, _ expected: stat) -> Bool {
    let opened = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard opened >= 0 else { return false }
    defer { close(opened) }
    var actual = stat()
    return fstat(opened, &actual) == 0 && isSameFile(expected, actual)
}

/// Exclusively creates an empty Complete-protected file in a pinned private
/// directory, for the C++ declaration in Platform/iOS/ProtectedFile.h.
///
/// No payload is written before protection and identity agree. An existing
/// leaf, including a symlink, is never replaced or removed.
///
/// - Parameters:
///   - directory: Borrowed descriptor for the application-owned parent.
///   - name: A fresh unpredictable leaf, without separators or dot components.
/// - Returns: The protected writable descriptor, owned by the caller, or -1
///   with `errno` set: EINVAL for a bad name, EEXIST for an existing leaf,
///   EIO for a refused creation, EACCES for any identity or protection
///   mismatch.
@_cdecl("ubiquittyCreateCompleteProtectedFile")
func createCompleteProtectedFile(_ directory: Int32, _ name: UnsafePointer<CChar>?) -> Int32 {
    guard let name, name.pointee != 0 else {
        errno = EINVAL
        return -1
    }
    // A leaf that is not UTF-8 has no Foundation spelling of the same bytes.
    guard let leafBytes = String(validatingCString: name), !leafBytes.contains("/"), leafBytes != ".", leafBytes != ".."
    else {
        errno = EINVAL
        return -1
    }
    var parent = stat()
    var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fstat(directory, &parent) == 0, isDirectory(parent), parent.st_uid == geteuid(), parent.st_mode & 0o077 == 0,
        fcntl(directory, F_GETPATH, &pathBuffer) == 0
    else {
        errno = EACCES
        return -1
    }
    let path = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard pathNamesDirectory(path, parent) else {
        errno = EACCES
        return -1
    }
    return autoreleasepool { () -> Int32 in
        let parentURL = NSURL(fileURLWithFileSystemRepresentation: pathBuffer, isDirectory: true, relativeTo: nil)
        guard let url = parentURL.appendingPathComponent(leafBytes, isDirectory: false) else {
            errno = EINVAL
            return -1
        }
        // withoutOverwriting is exclusive, including an existing symlink.
        // Foundation selects the public Complete protection class at creation;
        // the empty content carries no record before the checks below.
        do {
            try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            errno = EEXIST
            return -1
        } catch {
            errno = EIO
            return -1
        }

        let file = openat(directory, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var opened = stat()
        guard file >= 0 else {
            errno = EACCES
            return -1
        }
        guard fstat(file, &opened) == 0, isRegularFile(opened), opened.st_uid == geteuid(), opened.st_nlink == 1,
            opened.st_size == 0
        else {
            close(file)
            errno = EACCES
            return -1
        }
        func refuse() -> Int32 {
            var named = stat()
            if fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && isSameFile(opened, named) {
                _ = unlinkat(directory, name, 0)
            }
            close(file)
            errno = EACCES
            return -1
        }
        guard pathNamesDirectory(path, parent), fchmod(file, 0o600) == 0 else { return refuse() }

        // A file-reference URL follows this inode if its pathname changes.
        // Check that its fresh protection value describes our opened owner,
        // not a different leaf substituted during Foundation's path lookup.
        guard let reference = (url as NSURL).fileReferenceURL() as NSURL?,
            let referencePath = reference.filePathURL
        else { return refuse() }
        let referenced = referencePath.withUnsafeFileSystemRepresentation { representation in
            representation.map { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard referenced >= 0 else { return refuse() }
        var resolved = stat()
        var named = stat()
        let referencedIsOurs = fstat(referenced, &resolved) == 0 && isSameFile(opened, resolved)
        close(referenced)
        guard referencedIsOurs, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0, isSameFile(opened, named),
            pathNamesDirectory(path, parent)
        else { return refuse() }
        // Explicitly set the class on this identified owner too: a successful
        // creation request alone is not evidence that the filesystem used it.
        // Both operations use public Foundation protection values, not private
        // numeric classes. Refusal still happens before the first record byte.
        do {
            try reference.setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        } catch {
            return refuse()
        }
        reference.removeAllCachedResourceValues()
        var protection: AnyObject?
        do {
            try reference.getResourceValue(&protection, forKey: .fileProtectionKey)
        } catch {
            return refuse()
        }
        guard (protection as? URLFileProtection) == .complete || (protection as? String) == URLFileProtection.complete.rawValue,
            fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0, isSameFile(opened, named)
        else { return refuse() }
        return file
    }
}
#endif
