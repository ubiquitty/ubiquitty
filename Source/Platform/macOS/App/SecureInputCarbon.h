// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SecureInputCarbon.h — forward declarations for the two HIToolbox (Carbon)
// Secure Keyboard Entry functions, pulled into Swift via the bridging header.
//
// Swift cannot `import Carbon` in this target: the Carbon module fails to build
// under -cxx-interoperability-mode=default (its legacy headers are not C++-
// interop clean), so this header forward-declares the two symbols rather than
// including the Carbon umbrella. The Carbon framework is linked by the target,
// so they resolve at link time; they are the only ones the secure-input wrapper
// uses.
//

#pragma once

#include <MacTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

extern OSStatus EnableSecureEventInput(void);
extern OSStatus DisableSecureEventInput(void);

#ifdef __cplusplus
}
#endif
