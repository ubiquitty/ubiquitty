// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Ubiquitty-Bridging-Header.h — the C declarations the application's Swift
// sees beside its modules: the Carbon secure-input calls, and the harness's
// showcase door.
//

#include "SecureInputCarbon.h"
// The door a scenario hands its directory client the showcase host through.
// Declares only; the scenario files that use it compile into the harness
// build alone.
#include "../UITest/ShowcaseHostDoor.h"
