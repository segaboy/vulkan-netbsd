# Prebuilt Artifacts (build-once, reuse) — NetBSD Vulkan

> **Scope:** An optional fast path that lets the build scripts download prebuilt
> glslang and Mesa (Lavapipe) binaries from a GitHub Release instead of building
> them from source, when the target machine's environment matches the one the
> binaries were built on.
>
> **Status:** Living document. The mechanism is in place in the scripts; you
> supply the actual release assets.

Building glslang and Mesa from source is slow (Mesa especially — hundreds of
targets plus LLVM linking). When repeatedly setting up or refining the scripts
on the *same* environment, rebuilding every time is wasteful. This system lets
you build once, publish the binaries, and have the scripts fetch them.

## Why a fingerprint

A compiled binary is only safe to reuse on a machine that matches the one it was
built on. The Lavapipe driver links against a specific `libLLVM.so`, `libc`,
`libdrm`, and so on. Drop it onto a machine with a different LLVM or a newer
NetBSD and it may not load.

To make reuse safe, each artifact is tagged with an **environment fingerprint**:

```
netbsd<osrelease>_<arch>_llvm<llvmversion>_pkgsrc<branch>
# e.g. netbsd10.1_amd64_llvm19.1.7_pkgsrc2026Q2
```

computed by `compute_fingerprint` in `scripts/lib-artifacts.sh` from `uname`,
`llvm-config --version`, and the pkgsrc branch marker written by `setup-env.sh`
(`/usr/pkgsrc/.pkgsrc_branch`). The build scripts only use a prebuilt artifact
whose fingerprint matches the current machine; otherwise they build from source.
This is the "fast path with source fallback" model — speed when the environment
matches, correctness when it doesn't.

## Producing artifacts (one time)

On a machine where you have already built and installed glslang and Mesa
(`build-glslang.sh`, then `build-mesa.sh --build`):

```sh
ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/lib-artifacts.sh
ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/package-artifacts.sh
sh package-artifacts.sh
```

This writes fingerprinted tarballs into `/root/artifacts/`:

```
glslang-<fingerprint>.tar.gz   (+ .fingerprint)
mesa-<fingerprint>.tar.gz      (+ .fingerprint)
```

## Publishing

1. Create a GitHub Release on `segaboy/vulkan-netbsd`. Choose a tag — e.g.
   `prebuilt-latest` (simple, overwrite as you go) or a per-environment tag like
   `prebuilt-netbsd10.1-amd64`.
2. Upload the `.tar.gz` files from `/root/artifacts/` as release assets.

The asset filenames already contain the fingerprint, so multiple environments'
artifacts can live on the same release without colliding.

## Consuming

The build scripts check for a matching prebuilt artifact automatically:

- `build-glslang.sh` checks before building glslang.
- `build-mesa.sh` checks on the `--build` path (a configure-only run always
  builds from source, since there is nothing to skip).

Point the scripts at your release tag. Either edit `ARTIFACT_TAG` at the top of
`scripts/lib-artifacts.sh`, or set it at runtime:

```sh
ARTIFACT_TAG=prebuilt-latest sh build-mesa.sh --build
```

To force a source build even when an artifact exists (e.g. when refining the
build itself), set `NO_PREBUILT=1`:

```sh
NO_PREBUILT=1 sh build-mesa.sh --build
```

## Behavior summary

| Situation | Result |
|---|---|
| Matching artifact on the release | Downloaded, verified (gzip check), installed; source build skipped |
| No artifact / wrong fingerprint / 404 | Falls back to building from source |
| Download corrupt or not a gzip | Falls back to building from source |
| `NO_PREBUILT=1` | Always builds from source |
| `build-mesa.sh` without `--build` | Always configures from source (no artifact use) |

## Caveats

- **Fingerprint is a heuristic, not a guarantee.** It covers the factors most
  likely to break binary compatibility (OS release, arch, LLVM, pkgsrc branch)
  but not every possible difference. If a fetched artifact ever misbehaves,
  rebuild from source with `NO_PREBUILT=1` and re-package.
- **Artifacts are environment-specific.** A tarball built on NetBSD 10.1 / LLVM
  19.1.7 will not be offered to a machine on a different combination — by design.
- **You publish the assets.** The scripts never upload; producing and uploading
  artifacts is a manual step (`package-artifacts.sh` + GitHub Release).
