<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Tagged releases

Pushing an annotated `vMAJOR.MINOR.PATCH` App tag starts
[Release](../.github/workflows/release.yml). Tag Core first, then Kit, then App:
each tag must name the exact pin its consumer builds, all three `VERSION` files
must agree, the commits must belong to their respective mains, and `CI` and
`gitleaks` must have succeeded on all three exact revisions. A manual dispatch
retries an existing tag; it does not create or move tags.

The workflow checks out the product recursively at the tag. Its orchestration is separate from the immutable product tree. Signing and
publication run locally on the maintainer's Mac.
It reuses completed repository CI rather than repeating the Core and Kit test
batteries inside the release build.

## Artifacts and channels

The independent builds run in parallel, on native runners for both Linux
architectures. The macOS app embeds the exact static Linux hosts built by the
host jobs. CLI checks run natively against those same host binaries.

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

All platform jobs and packaged CLI smokes must pass. The final CI job produces
`release-preparation`, retained for 14 days: 18 nonempty prepared assets plus a
manifest binding their SHA-256 hashes, tagged Core/Kit/App commits and GitHub run.
The Mac app has ad-hoc signatures and release host policy. CI does not receive
signing keys, certificates, provisioning profiles, notarization credentials or
storage credentials. Its repository and registry access is read-only.

## Local signing and publication

Configure the local publisher executable once with
`git config ubiquitty.releasePublisher /path/to/publisher.py`. Check this Mac's
prerequisites without signing or uploading:

```sh
Scripts/release.sh --check
```

After the release cut and distribution are approved and tag CI succeeds:

```sh
Scripts/release.sh v0.4.1
```

The command downloads the successful CI preparation and verifies its complete
asset inventory, hashes, run provenance and exact tagged source composition.
It signs the prepared Mac bundle with the local Developer ID identity and
provisioning profile, notarizes and staples it, and signs the Sparkle feed using
the local keychain. It assembles and verifies all 23 required final assets and
their combined checksums before publication.

Versioned R2 files and GitHub draft assets are read back and checked before any
R2/Sparkle pointer advances or the GitHub draft becomes public. Failed preparation
leaves existing download pointers unchanged. A failed upload may leave versioned
files or a draft that can be retried. Publication across channels is sequential;
a pointer failure stops immediately and requires a retry. Public GitHub releases
cannot be overwritten. `--run ID` selects a particular successful preparation.
Temporary source, build and downloaded artifacts are removed; local checksums
and composition receipts are kept.

The Mac needs its existing Developer ID identity, notarization profile, Sparkle
key and provisioning profile, authenticated `gh`, and a local Wrangler login or
Cloudflare environment credentials. Keys stay in this Mac's keychains. CI needs
no signing or publication secrets and no private tooling checkout. The local
command never creates or moves tags, publishes the website changelog or uploads
to TestFlight. These actions remain separately controlled.

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

Before tagging, configure those image variables, confirm the three revision
checks are green and review the final pins. Pushing the tag prepares artifacts;
it does not sign, notarize or publish them.
