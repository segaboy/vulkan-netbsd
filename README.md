# vulkan-netbsd

An effort to bring the **Vulkan** software stack (Mesa / Lavapipe) to
**NetBSD**, and to document and automate the process so it can be reproduced
and maintained.

---

> ## Status: beta. Lavapipe Vulkan driver builds, installs, and registers on NetBSD
>
> **Milestone reached:** Mesa configures, compiles, links, **installs**, and
> **registers** the Lavapipe software Vulkan driver on NetBSD 10.1 amd64,
> against LLVM 19.1.7. The driver (`libvulkan_lvp.so`, ~17 MB) installs into
> `/usr/pkg/lib`, and its ICD manifest (advertising Vulkan API 1.4) installs
> into `/usr/pkg/share/vulkan/icd.d/`, so a Vulkan loader on the system can
> discover it. `ldd` resolves every dependency cleanly. The entire process
> (environment setup, dependency builds, the Mesa build, and installation) is
> automated end to end and reproducible on a fresh install.
>
> **Prebuilt binaries are coming.** The tooling to build, fingerprint, and
> publish prebuilt artifacts is in place, and the build scripts already know how
> to fetch and install a matching prebuilt instead of building from source. Once
> a build machine is publishing releases, installing the driver will be a
> download rather than a multi-hour build. That's the near-term direction.
>
> **What this is NOT (yet):**
> - **Running Vulkan programs needs the loader.** This project builds and
>   installs the Vulkan *driver* (the Lavapipe ICD). Actually executing a Vulkan
>   application also requires the Vulkan *loader* (`libvulkan.so.1`), which is
>   the next component to bring up. Runtime execution is therefore not yet
>   verified.
> - **One workaround is still in place.** The build applies `-Wno-error=format`
>   to sidestep GCC rejecting Mesa's `%m` format specifier on NetBSD. A proper
>   upstreamable fix (using `strerror(errno)`) is pending.
>
> Steps, scripts, and documents will continue to change as the loader and the
> release pipeline come together.

---

## Goal

NetBSD is currently the only major BSD without Vulkan support. The aim of this
project is to:

1. Build the Vulkan software stack (Mesa's Lavapipe driver, which runs on the
   CPU via LLVM and needs no GPU) on NetBSD.
2. Document every step, including the dead ends, so the process is reproducible.
3. Automate the setup so a fresh machine can be brought to a build-ready state
   with a couple of scripts.
4. Eventually feed the necessary fixes upstream (to Mesa and to pkgsrc) and
   provide prebuilt binaries or a pkgsrc package, so that Vulkan on NetBSD
   becomes something you can simply install rather than build from source.

## Scope and environment

- **Target OS:** NetBSD 10.1 (amd64), minimal ISO install.
- **Host:** VirtualBox VM.
- **Build goal only:** This targets *compilation and linkage* of the Vulkan
  stack. Runtime GPU acceleration is not available under VirtualBox; the
  software driver (Lavapipe) is the target.

## Repository layout

```
vulkan-netbsd/
├── docs/
│   ├── 01-environment-setup.md    Base system + pkgsrc + build deps
│   ├── 02-source-dependencies.md  Dependencies not in pkgsrc (built from source)
│   ├── 03-mesa-build.md           Configure + compile Mesa (Lavapipe); port notes
│   └── 04-prebuilt-artifacts.md   Build-once / reuse prebuilt binaries
└── scripts/
    ├── setup-env.sh               Automates the environment setup
    ├── build-glslang.sh           Builds glslang (required by Mesa; not in pkgsrc)
    ├── build-mesa.sh              Clones + configures + compiles Mesa (Lavapipe)
    ├── install-mesa.sh            Installs the built driver + ICD manifest
    ├── lib-artifacts.sh           Shared: fingerprint + prebuilt fetch helpers
    └── package-artifacts.sh       Packages built binaries into release tarballs
```

## Getting started

On a fresh, minimal NetBSD 10.1 (amd64) install, as root:

```sh
cd /root
ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/setup-env.sh
sh setup-env.sh
. /root/.profile

ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-glslang.sh
sh build-glslang.sh

ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-mesa.sh
sh build-mesa.sh --build

ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/install-mesa.sh
sh install-mesa.sh
```

`build-mesa.sh --build` clones, configures, and compiles Mesa, producing the
Lavapipe Vulkan driver (`libvulkan_lvp.so`). `install-mesa.sh` then installs
that driver and its ICD manifest into `/usr/pkg` and verifies the registration.

If a build is interrupted or the machine crashes, re-run the same command, the
build scripts detect the existing build and resume automatically.

Together, these scripts take a fresh minimal install all the way to an
installed, registered Vulkan software driver.

See `docs/01-environment-setup.md` for the full, commented walkthrough and
notes on running over SSH.

## Contributing / following along

This is a personal work-in-progress. Expect churn. The documentation is written
as a running record of what actually worked (and what didn't), so it doubles as
field notes for anyone attempting the same port.

## License

The original work in this repository, the scripts, documentation, and any
patches authored here, is released under the MIT License (see `LICENSE`).

This project builds, installs, and (optionally) redistributes third-party
software that is **not** covered by that license and retains its own:

- **Mesa**, primarily MIT-licensed (some components under other permissive
  licenses).
- **glslang**, permissive licenses (BSD-style, Apache 2.0, and Khronos terms).
- **LLVM**, Apache 2.0 with LLVM Exceptions. LLVM is installed separately via
  pkgsrc and is not redistributed by this project.

Prebuilt artifacts produced by `scripts/package-artifacts.sh` bundle the
relevant upstream license texts (under `share/licenses/`) so that binary
redistribution preserves each project's attribution. If you publish artifacts,
keep those files intact.
