<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Tagged releases

Pushing an annotated `vMAJOR.MINOR.PATCH` App tag starts
[Release](../.github/workflows/release.yml). Tag Core first, then Kit, then App:
each tag must name the exact pin its consumer builds, all three `VERSION` files
must agree, the commits must belong to their respective mains, and `CI` and
`gitleaks` must have succeeded on all three exact revisions. A manual dispatch
retries an existing tag; it does not create or move tags.

The workflow checks out the product recursively at the tag. Its orchestration
and pinned private signing tools are separate from the immutable product tree.
It reuses completed repository CI rather than repeating the Core and Kit test
batteries inside the release build.

## Artifacts and channels

The independent builds run in parallel, on native runners for both Linux
architectures. The macOS app embeds the exact static Linux hosts built by the
host jobs. CLI checks run natively against the hosts extracted from that same
Mac archive.

| Artifact | Distribution |
|---|---|
| Developer ID signed, notarized and stapled Apple-silicon macOS zip | GitHub, R2, Sparkle |
| x86_64 and aarch64 AppImages, `.zsync` and matching support sources | GitHub, R2 |
| Static Linux hosts for x86_64/arm64 and the signed macOS arm64 host | GitHub, R2 |
| Static Linux `ubq` for x86_64/arm64, notices and group checksums | GitHub, R2 |
| Servable WebAssembly/browser distribution, with fonts and notices | GitHub |
| iOS device and simulator development app bundles | GitHub |
| Emacs and Neovim source packages, including their MIT licenses | GitHub |
| Recursive App + Kit + Core source archive, including the BSD wscons frontend | GitHub |
| Exact source composition and combined `SHA256SUMS` | GitHub |

The iOS bundles use development signing and are not App Store or TestFlight
uploads. Device installation requires signing for the recipient. BSD wscons is
distributed as source; this workflow does not claim to produce or test a native
OpenBSD/NetBSD executable. Intel macOS remains outside the release matrix.

All platform jobs and packaged CLI smokes must pass before finalization. The
final job verifies every required nonempty artifact, rejects conflicting bytes
with the same name, and computes the complete checksums before moving any
R2/Sparkle pointer or publishing the GitHub draft. A failed build leaves the
existing download pointers unchanged. Versioned R2 files and a private GitHub
draft may already exist and are reused on retry. Website changelog publication
is separate.

## One-time repository setup

The App repository needs the following Actions secrets. Values belong in GitHub
Secrets, not source files or job output:

| Secret | Purpose |
|---|---|
| `UBIQUITTY_RELEASE_TOOLS_SSH_KEY` | Read-only deploy key for the release tooling checkout |
| `UBIQUITTY_RELEASE_TOKEN` | Alternative read-only token for the private tools checkout |
| `SPARKLE_ED_PRIVATE_KEY` | Exported Sparkle Ed25519 signing key |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `MACOS_DEVELOPER_ID` | Developer ID identity |
| `MACOS_PROVISIONING_PROFILE_BASE64` | Developer ID provisioning profile with the app's keychain-sharing group |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect Team API key for Apple notarization |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_APP_PASSWORD` | Alternative notarization credentials using an app-specific password |
| `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | Existing release bucket publication |

The signing implementation is pinned to private tools commit
`450b12a353bc1205c71e32b67a36cdf31ab559f6`. Update that pin when
changing the signing or publishing procedure. Temporary certificate, Sparkle
key and provisioning files are removed at the end of the macOS job.
Configure one private-tools reader credential. A deploy key is restricted to
the tools repository; GitHub release writes use the job's own token.
Configure one complete notarization credential set. The Team API key uses the
existing `.p8` file; the workflow stores a temporary notarytool profile and
removes the key file after the job.

### Immutable Linux PGO toolchains

The two repository variables `PGO_LINUX_X86_64_IMAGE` and
`PGO_LINUX_ARM64_IMAGE` name native OCI images by manifest digest, for example
`ghcr.io/ubiquitty/pgo-toolchains@sha256:...`. Make the exact training images
available in that registry before the first tagged build. The images are kept
in the corresponding native trainers' Docker stores. Their expected configuration
digests are recorded in Core's matching `.trained-toolchain` files.

The release job uses the trainers' containerd image store on both architectures.
Its repository token authenticates the registry pull with read-only package
access. It then compares Docker's
image identity with the committed profile provenance before assigning the CI
recipe's local name. Docker's stores report different identities for an image;
[the image-store configuration](https://docs.docker.com/engine/storage/containerd/)
is set on the disposable release runner before any container starts. The existing compiler, recipe and profile checks still
run. Rebuilding a similar image or using an ordinary hosted-CI image is
insufficient: it can have a different compiler or image identity. Publishing
these two existing images is a one-time preparation action, not a retrain.

Before tagging, configure those variables and the secrets, confirm the three
revision checks are green, and review the final pins. Creating the tag then
authorizes this workflow's configured GitHub and R2/Sparkle publication.
