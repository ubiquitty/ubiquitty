// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include <cmath>

// glibc 2.43 gives sqrtf a new default symbol version. Keep the established
// libm entry point so builds on that toolchain retain the Linux release floor.
#if defined(__GLIBC__) && defined(__aarch64__)
extern "C" float ubiquittyLegacySqrtf(float);
asm(".symver ubiquittyLegacySqrtf, sqrtf@GLIBC_2.17");
#elif defined(__GLIBC__) && defined(__x86_64__)
extern "C" float ubiquittyLegacySqrtf(float);
asm(".symver ubiquittyLegacySqrtf, sqrtf@GLIBC_2.2.5");
#else
extern "C" float __real_sqrtf(float);
#endif

// GNU-compatible linkers route sqrtf references here through --wrap=sqrtf.
extern "C" float __wrap_sqrtf(float value)
{
#if defined(__GLIBC__) && (defined(__aarch64__) || defined(__x86_64__))
    return ubiquittyLegacySqrtf(value);
#else
    return __real_sqrtf(value);
#endif
}
