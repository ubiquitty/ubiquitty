// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <glib-object.h>

#include <memory>

namespace Ubiquitty::Linux::GTK {

/// Drops the one strong reference a `GObjectPointer` holds.
struct GObjectRelease {
    void operator()(gpointer object) const
    {
        if (object)
            g_object_unref(object);
    }
};

/// One strong reference to a GObject, released with its owner.
template<typename Object>
using GObjectPointer = std::unique_ptr<Object, GObjectRelease>;

/// Takes ownership of a newly created object, sinking a floating reference
/// (every new GtkWidget's) so the owner holds a real one whether or not a
/// container also holds the object.
///
/// - Parameter object: A newly created object.
/// - Returns: The owning pointer.
template<typename Object>
[[nodiscard]] GObjectPointer<Object> adoptSunk(Object* object)
{
    return GObjectPointer<Object>(static_cast<Object*>(g_object_ref_sink(object)));
}

} // namespace Ubiquitty::Linux::GTK
