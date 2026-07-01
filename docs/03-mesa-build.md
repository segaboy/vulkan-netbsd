# Building Mesa with the Vulkan Software Driver (Lavapipe) on NetBSD 10.1

> **Scope:** Building Mesa's Vulkan software driver (Lavapipe / `swrast`) on a
> NetBSD 10.1 (amd64) system prepared per `01-environment-setup.md` and with
> glslang built per `02-source-dependencies.md`.
>
> **Status:** Living document. As of this writing, Mesa **configures, compiles,
> and links** the Lavapipe Vulkan driver (`libvulkan_lvp.so`) on NetBSD. This
> is a build-and-link result; runtime execution under VirtualBox is out of
> scope (no GPU / software-only). One source-level workaround (`-Wno-error=
> format`, see below) is currently applied and has a proper upstreamable fix
> still pending.

The automated path is `scripts/build-mesa.sh` (see the Quick start below). The
rest of this document explains each step and records the NetBSD-specific issues
encountered.

Prerequisites:
- `01-environment-setup.md` completed (compiler, X11 sets, pkgsrc, meson/ninja,
  LLVM 19.1.7, and a python3 with `mako`, `yaml`, and `packaging`).
- `02-source-dependencies.md` completed (`glslangValidator` on `PATH`).

---

## Quick start (automated)

```sh
cd /root
ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-mesa.sh
sh build-mesa.sh          # clone + configure (stops after a successful configure)
sh build-mesa.sh --build  # also run the ninja compile + install
```

The script installs `bison`/`flex`, clones Mesa, and runs the Meson configure.
It defaults to configure-only; the compile step is behind `--build`.

---

## 1. Remaining build tools: bison and flex

Mesa's configure requires a parser generator and lexer. It accepts `bison` or
`byacc` for the parser and needs `flex` for the lexer. On a minimal install
neither is present, and configure fails with:

```
Program 'byacc' not found or not executable
```

Install both:

```sh
pkg_add bison flex
```

---

## 2. Clone Mesa

```sh
mkdir -p /usr/src/graphics
cd /usr/src/graphics
git clone https://gitlab.freedesktop.org/mesa/mesa.git
```

Mesa is cloned into `/usr/src/graphics` (scratch space on the VM, not committed
to this repo). This is a deliberately broad location: Mesa is not a Vulkan-only
project (it also implements OpenGL, GLES, OpenCL); we build it *for* its Vulkan
(Lavapipe) driver.

---

## 3. Configure with Meson

```sh
cd /usr/src/graphics/mesa
rm -rf build
meson setup build \
  --prefix=/usr/pkg \
  -Dbuildtype=release \
  -Dvulkan-drivers=swrast \
  -Dgallium-drivers=llvmpipe \
  -Dplatforms=x11 \
  -Dglx=disabled \
  -Degl=disabled \
  -Dgbm=disabled
```

Flag notes:

- **`-Dvulkan-drivers=swrast`** — Lavapipe, the software Vulkan driver (target).
- **`-Dgallium-drivers=llvmpipe`** — the LLVM-backed software rasterizer
  Lavapipe builds on.
- **`-Dplatforms=x11`** — window-system integration using the X11 libraries
  from the `xbase`/`xcomp` sets.
- **`-Dglx=disabled -Degl=disabled -Dgbm=disabled`** — disable OpenGL-adjacent
  pieces we don't need, reducing the surface for platform-specific issues.
- LLVM is auto-detected via `llvm-config` on `PATH`; no explicit flag needed.
  (Do **not** pass a hand-typed `-Dllvm=...`; see the port notes.)

A successful configure reports, among other things:
`Vulkan drivers: swrast`, `LLVM ... Version: 19.1.7`,
`Gallium ... Drivers: llvmpipe`, and a build-target count.

---

## 4. Compile and link

```sh
cd /usr/src/graphics/mesa
ninja -C build -j$(sysctl -n hw.ncpu) 2>&1 | tee /root/mesa-build.log
```

The `tee` captures a persistent log; on a flaky SSH link this lets you
reconnect and inspect progress. The build is long (hundreds of targets plus
LLVM linking).

A successful build produces the Lavapipe Vulkan ICD:

```
Linking target src/gallium/targets/lavapipe/libvulkan_lvp.so
```

### Verification

```sh
ls -la build/src/gallium/targets/lavapipe/libvulkan_lvp.so
ldd    build/src/gallium/targets/lavapipe/libvulkan_lvp.so
```

`ldd` should resolve every dependency, notably `libLLVM.so.19.1` (from pkgsrc),
`libdrm.so.3` and `libxcb.so.2` (from the X11 sets), and the base C/C++
runtime. A clean resolution means the driver compiled *and* linked correctly on
NetBSD.

---

## Port notes / NetBSD-specific issues

### `%m` format specifier rejected by GCC (`-Werror=format`)

**Symptom:** the build fails early in `src/vulkan/runtime/vk_drm_syncobj.c`
with many instances of:

```
error: %m is only allowed in syslog(3) like functions [-Werror=format=]
```

**Cause:** Mesa uses the `%m` conversion (a glibc/syslog extension that expands
to `strerror(errno)`) in `vk_errorf(...)` format strings. On NetBSD, GCC's
`-Werror=format` rejects `%m` in functions it does not recognize as
syslog-like, so every such call is a hard error.

**Current workaround (applied):** demote the format error to a warning so the
build proceeds, while still surfacing the sites for a proper fix later:

```sh
meson configure build -Dc_args="-Wno-error=format"
```

`meson configure` amends the existing build directory in place (no need to wipe
it). `-Wno-error=format` is used rather than `-Wno-format` so the warnings
remain visible. NetBSD's libc `printf` does support `%m` at runtime, so the
workaround is safe for building and linking; it only sidesteps GCC's static
check.

**Proper fix (pending, upstreamable):** replace `%m` in these format strings
with an explicit `%s` argument passing `strerror(errno)`. This is a genuine
NetBSD-portability improvement suitable for submission to Mesa upstream. Tracked
as a TODO.

### Non-fatal `alloca(3)` linker warning

During linking, the `ddebug` gallium debug utility triggers:

```
warning: reference to the libc supplied alloca(3); this most likely will not
work. Please use the compiler provided version of alloca(3) ...
```

This is a **warning only**, originates in a debug utility (not the Lavapipe
driver), and does not affect `libvulkan_lvp.so`. Recorded for completeness.

### Things that did NOT need patching

For the record, the following built cleanly on NetBSD with no source changes:
the LLVM linkage (LLVM 19.1.7 from pkgsrc), libdrm/X11 integration from the
`xbase`/`xcomp` sets, glslang, and the Lavapipe frontend itself. The only
source-level obstacle so far is the `%m` format issue above.
