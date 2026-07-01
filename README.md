# vulkan-netbsd

An effort to bring the **Vulkan** software stack (Mesa / Lavapipe) to
**NetBSD**, and to document and automate the process so it can be reproduced
and maintained.

---

> ## Status: alpha — Lavapipe Vulkan driver builds and links on NetBSD
>
> **Milestone reached:** Mesa now **configures, compiles, and links** the
> Lavapipe software Vulkan driver (`libvulkan_lvp.so`, ~17 MB) on NetBSD 10.1
> amd64, against LLVM 19.1.7. `ldd` resolves every dependency cleanly. The
> environment setup, dependency builds, and Mesa build are automated end to end.
>
> **What this is:** a confirmed **build-and-link** result — the whole toolchain
> compiles and the driver binary links with all dependencies satisfied.
>
> **What this is NOT (yet):**
> - **Runtime execution is out of scope / unverified.** The target is a software
>   driver built under VirtualBox with no GPU; this project verifies the build,
>   not that Vulkan programs run.
> - **One workaround is still in place.** The build applies `-Wno-error=format`
>   to sidestep GCC rejecting Mesa's `%m` format specifier on NetBSD. A proper
>   upstreamable fix (using `strerror(errno)`) is pending.
>
> Steps, scripts, and documents will continue to change. Treat this as a
> working record of an active port, not a finished product.

---

## Goal

NetBSD is currently the only major BSD without Vulkan support. The aim of this
project is to:

1. Build the Vulkan software stack (Mesa's Lavapipe driver, which runs on the
   CPU via LLVM and needs no GPU) on NetBSD.
2. Document every step, including the dead ends, so the process is reproducible.
3. Automate the setup so a fresh machine can be brought to a build-ready state
   with a couple of scripts.
4. Eventually feed the necessary fixes upstream (to Mesa and to pkgsrc) so that
   Vulkan on NetBSD becomes something you can simply install.

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
│   └── 03-mesa-build.md           Configure + compile Mesa (Lavapipe); port notes
└── scripts/
    ├── setup-env.sh               Automates the environment setup
    ├── build-glslang.sh           Builds glslang (required by Mesa; not in pkgsrc)
    └── build-mesa.sh              Clones + configures Mesa (Vulkan swrast/Lavapipe)
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
sh build-mesa.sh
```

The last script clones Mesa and runs the Meson configure. It stops after a
successful configure by default; the compile step (`ninja`) is gated behind an
explicit `--build` flag because it is not yet confirmed working end-to-end.

See `docs/01-environment-setup.md` for the full, commented walkthrough and
notes on running over SSH.

## Contributing / following along

This is a personal work-in-progress. Expect churn. The documentation is written
as a running record of what actually worked (and what didn't), so it doubles as
field notes for anyone attempting the same port.
