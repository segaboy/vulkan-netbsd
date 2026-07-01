# vulkan-netbsd

An effort to bring the **Vulkan** software stack (Mesa / Lavapipe) to
**NetBSD**, and to document and automate the process so it can be reproduced
and maintained.

---

> ## ⚠️ Status: pre-alpha — this does not work yet
>
> **There is no working Vulkan build here yet.** This repository is an active,
> in-progress porting effort. The environment setup and dependency builds
> documented so far do run, but the end goal — a successful end-to-end Vulkan
> (Lavapipe) build on NetBSD — has **not** been reached. Details are still
> being worked out.
>
> Nothing here should be treated as final or authoritative. Steps, scripts, and
> documents will change as the port progresses. If you're looking for working
> Vulkan on NetBSD today, this isn't it — yet.

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
│   └── 02-source-dependencies.md  Dependencies not in pkgsrc (built from source)
└── scripts/
    ├── setup-env.sh               Automates the environment setup
    └── build-glslang.sh           Builds glslang (required by Mesa; not in pkgsrc)
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
```

See `docs/01-environment-setup.md` for the full, commented walkthrough and
notes on running over SSH.

## Contributing / following along

This is a personal work-in-progress. Expect churn. The documentation is written
as a running record of what actually worked (and what didn't), so it doubles as
field notes for anyone attempting the same port.
