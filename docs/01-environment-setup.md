# Environment Setup Guide: NetBSD 10.1 Minimal Install

> **Scope:** This guide covers environment preparation on a **minimal install
> of NetBSD 10.1 (amd64)** — specifically the base ISO installer with no
> additional sets selected during installation. If you used a cloud image,
> a pre-built appliance, or selected additional sets during install, your
> starting state will differ.
>
> **Status:** This is a living document. It reflects what has worked so far
> during an active porting effort. Steps may be revised as the build process
> evolves. Do not treat this as a final reference until a successful end-to-end
> Vulkan build has been confirmed.

This guide documents the steps to prepare a NetBSD 10.1 (amd64) minimal
install system for building the Vulkan software stack (Mesa/Lavapipe). It
covers everything from a fresh install up to the point where the Mesa source
is ready to be cloned and configured.

The goal is a **build environment**. Runtime GPU acceleration is not available
under VirtualBox; the target is the LLVM-backed software Vulkan driver
(Lavapipe), which does not require kernel-side GPU support.

---

## 0. Prerequisites

Install NetBSD 10.1 (amd64) from the **official installer ISO** — not a cloud
image. Cloud images (e.g. from bsd-cloud-image.org) run cloud-init on boot and
will hang in a loop trying to reach the cloud metadata service at
`169.254.169.254`, which does not exist in a VirtualBox NAT network.

VirtualBox VM configuration:

- CPU: 4 cores (the Mesa build is heavily parallel; more cores = faster)
- RAM: 8 GB
- Disk: 30 GB or more
- Network: NAT (default) is sufficient

Log in as `root`.

---

## 1. Verify the system

Confirm architecture, network, and available disk space before starting:

```sh
uname -a                    # expect: NetBSD ... 10.1 ... amd64
ifconfig -a | grep inet     # expect a 10.0.2.x address on NAT
df -h                       # expect ~30G+ free on /
```

---

## 2. Install the compiler set

A minimal ISO install does **not** include a C compiler. NetBSD ships the
toolchain as a separate distribution set (`comp`). Install it directly into
the base system:

```sh
cd /root
ftp https://cdn.NetBSD.org/pub/NetBSD/NetBSD-10.1/amd64/binary/sets/comp.tar.xz
tar -xpJf comp.tar.xz -C /
cc --version                # expect: gcc (NetBSD ...) 10.5.0
```

> **Note:** Run the `ftp` download and the `tar` extract as *separate*
> commands. If both are typed on one line, `ftp` consumes the whole line and
> the extract never runs.

---

## 3. Install the X11 sets

The DRM and X11 libraries that Mesa depends on (`libdrm`, `libxshmfence`,
`libX11`, `libxcb`, and friends) are **not** in pkgsrc — they are provided by
NetBSD's X11 distribution sets. Install both the runtime (`xbase`) and the
development headers (`xcomp`):

```sh
cd /root
ftp https://cdn.NetBSD.org/pub/NetBSD/NetBSD-10.1/amd64/binary/sets/xbase.tar.xz
ftp https://cdn.NetBSD.org/pub/NetBSD/NetBSD-10.1/amd64/binary/sets/xcomp.tar.xz
tar -xpJf xbase.tar.xz -C /
tar -xpJf xcomp.tar.xz -C /
```

These install into `/usr/X11R7/`.

---

## 4. Fetch and bootstrap pkgsrc

Download the current stable pkgsrc branch, extract it, and bootstrap the
package tools:

```sh
cd /root
ftp https://cdn.NetBSD.org/pub/pkgsrc/pkgsrc-2026Q2/pkgsrc.tar.gz
tar -xzf pkgsrc.tar.gz -C /usr
cd /usr/pkgsrc/bootstrap
./bootstrap --prefix /usr/pkg
```

The bootstrap takes a few minutes and builds a working `bmake` and `pkg_add`.

> **Note:** If a previous bootstrap attempt failed, remove its work directory
> before retrying:
> ```sh
> rm -rf /usr/pkgsrc/bootstrap/work
> ```

---

## 5. Configure the environment

Set up the shell environment so the toolchain and pkgsrc tools can find each
other:

```sh
export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH
export PKG_PATH="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/10.1/All"
export CPPFLAGS="-I/usr/X11R7/include -I/usr/pkg/include"
export LDFLAGS="-L/usr/X11R7/lib -Wl,-R/usr/X11R7/lib -L/usr/pkg/lib -Wl,-R/usr/pkg/lib"
export PKG_CONFIG_PATH="/usr/X11R7/lib/pkgconfig:/usr/pkg/lib/pkgconfig"
```

Make them persist across reboots:

```sh
cat >> /root/.profile << 'EOF'
export PATH=/usr/pkg/bin:/usr/pkg/sbin:$PATH
export PKG_PATH="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/amd64/10.1/All"
export CPPFLAGS="-I/usr/X11R7/include -I/usr/pkg/include"
export LDFLAGS="-L/usr/X11R7/lib -Wl,-R/usr/X11R7/lib -L/usr/pkg/lib -Wl,-R/usr/pkg/lib"
export PKG_CONFIG_PATH="/usr/X11R7/lib/pkgconfig:/usr/pkg/lib/pkgconfig"
EOF
```

> **Two things to get right about `PKG_PATH`:**
> - The directory is **case-sensitive**: it is `All`, not `ALL`.
> - Do **not** leave a trailing slash — it produces a double slash
>   (`.../All//cmake`) and `pkg_add` will report "Not Found".

---

## 6. Install core packages

```sh
pkg_add cmake git mozilla-rootcerts-openssl
```

`mozilla-rootcerts-openssl` provides the CA certificate bundle. Without it,
HTTPS fetches and git clones fail with certificate validation errors.

---

## 7. Install build tools

```sh
pkg_add meson ninja python312 pkgconf py312-mako
```

> **Note:** `ninja` may conflict with `ninja-build`, which is often already
> installed as a dependency. This is harmless — verify with `ninja --version`.

Why these tools:

- **meson / ninja** — Mesa's build system.
- **python3 / py312-mako** — Mesa uses Python with the Mako templating
  library at build time to auto-generate C source files before compilation.

---

## 8. Create the `python3` symlink

Mesa's build scripts invoke `python3`, but pkgsrc installs the interpreter as
`python3.12`. Create the symlink:

```sh
ln -sf /usr/pkg/bin/python3.12 /usr/pkg/bin/python3
python3 --version           # expect: Python 3.12.x
```

---

## 9. Install LLVM

LLVM is required for **Lavapipe**, the software Vulkan driver. Lavapipe uses
LLVM to JIT-compile shaders on the CPU at runtime, allowing Vulkan to function
without a real GPU.

Install the prebuilt binary package:

```sh
pkg_add llvm
llvm-config --version       # expect: 19.1.7
```

---

## 10. Verify the base libraries

The DRM and X11 libraries from the `xbase`/`xcomp` sets (Step 3) do **not**
need to be installed via pkgsrc. Confirm they are present and discoverable:

```sh
pkg-config --modversion libdrm      # expect: 2.4.109
pkg-config --modversion xshmfence   # expect: 1.3.1
ls /usr/X11R7/lib/libX11*
ls /usr/X11R7/lib/libxcb*
```

---

## Environment summary

| Component | Source | Version |
|---|---|---|
| C compiler (gcc) | `comp` set | 10.5.0 |
| X11 + DRM libraries | `xbase` / `xcomp` sets | libdrm 2.4.109 |
| pkgsrc | 2026Q2 branch | — |
| cmake, git | pkgsrc binary | — |
| meson | pkgsrc binary | 1.10.1 |
| ninja | pkgsrc binary | 1.13.2 |
| python3 | pkgsrc binary | 3.12.x |
| LLVM | pkgsrc binary | 19.1.7 |

---

## Appendix: Pitfalls encountered

1. **Cloud image boot loop.** A bsd-cloud-image.org image hung on cloud-init
   metadata lookups at boot. Fix: use the plain installer ISO.

2. **No C compiler after minimal install.** Bootstrap failed with "no
   acceptable C compiler found." Fix: install the `comp` set before
   bootstrapping pkgsrc.

3. **`ftp` + `tar` on one line.** The extract was silently skipped. Fix:
   separate commands.

4. **Stale bootstrap work directory.** Re-running `./bootstrap` after a
   failure aborted with "work already exists." Fix: `rm -rf
   /usr/pkgsrc/bootstrap/work` before retrying.

5. **`PKG_PATH` unset.** `pkg_add` reported "no pkg found" for everything.
   Fix: set `PKG_PATH` to the binary mirror (Step 5).

6. **`PKG_PATH` casing / double slash.** `ALL` vs `All`, and a trailing slash
   both caused "Not Found." Fix: use exactly `.../10.1/All` with no trailing
   slash.

7. **X11/DRM libraries not in pkgsrc.** `libdrm`, `libX11`, `libxcb`,
   `libxshmfence` are not pkgsrc packages — they come from `xbase`/`xcomp`.
   Fix: install the X11 sets (Step 3).

8. **`ninja` vs `ninja-build` conflict.** Harmless; `ninja-build` already
   provides the binary.

9. **`python3` not found.** pkgsrc installs `python3.12`, not `python3`.
   Fix: symlink (Step 8).
