// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ShippedResources.swift — where the files this code ships with are found.
//
// The shaders, fonts and icons ride the bundle of the binary this module is
// linked into, and that is the only place they are looked for. Linked into an
// application, that bundle is the application's own. Packaged as
// UbiquittyKit.framework, it is the framework: the application around it is a
// host that carries none of these files, so `Bundle.main` would find nothing.
//
// Foundation alone, so a driver compiling one renderer file beside this one
// needs no Core and no interoperability flags.

import Foundation

/// The bundle this module's resources ship in, and the directories inside it.
package enum ShippedResources {
    /// The bundle holding the binary this module is linked into: the
    /// framework when it is packaged as one, the application otherwise.
    package static var bundle: Bundle {
        Bundle(for: BundleToken.self)
    }

    /// The shipped font files and their licences: `fonts` in ``bundle``'s
    /// resources.
    package static let fontDirectory: URL? = directory(named: "fonts")

    /// A directory of ``bundle``'s resources.
    ///
    /// - Parameter name: The directory's name inside the resources.
    /// - Returns: Its location, or nil for a bundle with no resources.
    package static func directory(named name: String) -> URL? {
        bundle.resourceURL?.appendingPathComponent(name, isDirectory: true)
    }
}

/// The class whose image ``ShippedResources/bundle`` names.
private final class BundleToken {}
