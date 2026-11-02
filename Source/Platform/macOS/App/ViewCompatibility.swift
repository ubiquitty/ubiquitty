// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ViewCompatibility.swift — deployment-target shims shared by every SwiftUI
// surface (the target floor is macOS 13).
//

import SwiftUI

extension View {
    // onChange's two-parameter closure form requires macOS 14; this presents
    // the zero-parameter shape every caller wants on both OS generations.
    @ViewBuilder
    func onChangeCompatibility<Value: Equatable>(
        of value: Value,
        perform action: @escaping () -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, _ in action() }
        } else {
            onChange(of: value) { _ in action() }
        }
    }
}
