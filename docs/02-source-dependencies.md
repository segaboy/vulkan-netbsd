# Source-Built Dependencies: NetBSD 10.1

> **Scope:** This document covers dependencies that are **not available in
> pkgsrc** for NetBSD and must be built from source to build the Vulkan stack.
> It is separate from `01-environment-setup.md`, which covers packages
> installable via `pkg_add` and the NetBSD distribution sets.
>
> **Status:** Living document. Each dependency listed here is, so far, a
> confirmed requirement for the build to proceed. Entries are added as they
> are encountered during the port. This is not a final list — later stages may
> add or remove requirements.

Each dependency below follows the same pattern: clone the upstream source,
build with CMake, install into the pkgsrc prefix (`/usr/pkg`), and verify the
resulting binary is on `PATH`. These build directories live on the VM (under
`/usr/src/graphics`) as scratch space — they are **not** committed to this
repository. Only the knowledge of *how* to build them lives here.

Prerequisite: complete `01-environment-setup.md` first. These builds rely on
the compiler, CMake, and the environment configured there.

---

## glslang

**Upstream:** https://github.com/KhronosGroup/glslang
**Provides:** `glslangValidator` — the Khronos GLSL/ESSL-to-SPIR-V reference
compiler.
**Why it's needed:** Mesa's Meson configure requires `glslangValidator` at
build time to compile the Vulkan driver's built-in shaders into SPIR-V.
Without it, configuration fails at:

```
Program 'glslangValidator' not found or not executable
```

### Not available in pkgsrc

**glslang is not packaged in pkgsrc for NetBSD.** `pkg_add glslang` fails with
"no pkg found", and it is not present on the binary package mirror. It exists
in FreeBSD ports and most Linux distributions, but not in the NetBSD packages
collection. Building it from source is currently the only way to satisfy this
dependency on NetBSD — and is, so far, a hard requirement for building Mesa's
Vulkan driver.

### Quick start (automated)

An automation script performs every step in this section. After completing
`01-environment-setup.md` (or running `scripts/setup-env.sh`), run:

```sh
cd /root
ftp https://raw.githubusercontent.com/segaboy/vulkan-netbsd/main/scripts/build-glslang.sh
sh build-glslang.sh            # build + install glslang
sh build-glslang.sh --clean    # force a fresh build from scratch
```

The script sources `/root/.profile`, verifies that `cmake` and `git` are
present (failing with a clear message if the environment setup hasn't been run
yet), checks for a matching prebuilt artifact (see `04-prebuilt-artifacts.md`)
and falls back to source if none exists, clones glslang, builds it, installs it
into `/usr/pkg`, and verifies `glslangValidator` is on `PATH`. It is
**idempotent** — if the glslang source is already present it pulls the latest
instead of failing, so it is safe to re-run.

**Resuming after an interruption or crash:** if the build is interrupted, run
the same command again — the script detects the existing configured build
directory and resumes instead of starting over. Use `--clean` to force a fresh
build from scratch.

All output is also written to `/root/vulkan-netbsd-glslang.log`, so a run can be
inspected afterward or tailed from a second SSH session if the connection drops.

The rest of this section documents the steps the script performs, for
reference and manual execution.

### Build steps (manual)

```sh
cd /usr/src/graphics
git clone https://github.com/KhronosGroup/glslang.git
cd glslang

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/pkg \
  -DENABLE_OPT=OFF \
  -DENABLE_GLSLANG_BINARIES=ON \
  -DGLSLANG_TESTS=OFF

cmake --build build -j$(sysctl -n hw.ncpu)
cmake --install build
```

Flag notes:

- **`-DENABLE_OPT=OFF`** — disables the optional SPIRV-Tools optimizer
  dependency, which would otherwise be fetched by glslang's
  `update_glslang_sources.py` helper script. We only need the standalone
  `glslangValidator` binary, so this dependency is unnecessary and skipping it
  avoids an extra source fetch.
- **`-DENABLE_GLSLANG_BINARIES=ON`** — ensures the standalone binaries
  (including `glslangValidator`) are built, not just the libraries.
- **`-DGLSLANG_TESTS=OFF`** — skips the test suite; not needed for producing
  the tool.

### Verification

```sh
which glslangValidator        # expect: /usr/pkg/bin/glslangValidator
glslangValidator --version
```

Expected output includes `Glslang Version: 11:16.3.0` (or newer), along with
the ESSL/GLSL/SPIR-V version lines.

### Port notes

glslang built cleanly on NetBSD 10.1 amd64 with **no source patches
required**. The CMake configure and build completed without NetBSD-specific
modifications. This is the ideal case — a pure from-source build with no
porting work needed, only the fact that it isn't packaged.
