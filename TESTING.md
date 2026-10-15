# Testing Policy

Hardware testing is the most expensive step in this project. One maintainer tests 3 operating systems × Game Mode / Desktop Mode × multiple displays, on a single ROG Ally and XG Mobile. This policy keeps hardware passes to the minimum a change actually needs. Everything that can be checked without the XG Mobile is checked automatically.

**Every plan, feature, and PR must state its test tier (see [Choosing a tier](#choosing-a-tier)).**

---

## Test tiers

| Tier | Name | Hardware | Typical time |
|---|---|---|---|
| **0** | Automated | None (local + CI) | Minutes |
| **1** | Single-OS smoke | Ally (+ XG Mobile), one OS, one display | ~15 min |
| **2** | Per-OS functional | Ally + XG Mobile, each OS whose code path changed, one display | ~30 min per OS |
| **3** | Full matrix | Everything: all OSes × Game/Desktop × all displays | Hours |

### Tier 0: Automated (required for every change)
Runs on every commit, both locally and in CI (`.github/workflows/tests.yml`). Nothing reaches hardware until Tier 0 passes.

Run it all with one command, as a normal user (it refuses to run as root):

```bash
bash tests/run-all.sh
```

That runs, in order:
- `python3 -m py_compile main.py`
- `bash -n bin/*`
- `shellcheck --severity=error` on `bin/*` and the test scripts (skipped with a warning if shellcheck isn't installed locally; required in CI)
- `pnpm test:audit`: the path audit (`tests/audit/path-audit.bats`), as a gate. It proves every absolute path in the in-scope `bin/` scripts is `$ROOT`-prefixed before any script is executed.
- `pnpm build` (no TypeScript errors)
- `pnpm test`, which runs the three suites:
  - `pnpm test:py`: pytest, `tests/python/`. Backend logic (`main.py`) with a fake `decky` module and stub scripts. If `pytest` isn't importable, `run-all.sh` creates `.venv/` and installs `requirements-dev.txt`.
  - `pnpm test:bin`: bats, `tests/bin/`. Every test file checks the path audit in its `setup_file` (once per bats run) and runs no script if it fails, so running a single file or `bats -f` is gated too. The `bin/` scripts run against a fake sysfs/rootfs, with `modinfo`, `systemctl`, `lspci`, `steamos-readonly` and the other system commands shimmed on `PATH`.
  - `pnpm test:ui`: vitest, `src/**/*.test.ts`. Frontend result handling (`src/lib/notify.tsx`).

**Rule:** if a behavior *can* be tested at Tier 0, add a Tier 0 test for it instead of adding a hardware checklist item. Examples: exit-code → message mapping, OS/vendor branching in scripts, environment-variable injection and cleanup, result shapes, log-path resolution.

### Tier 1: Single-OS smoke
Use for changes to **OS-agnostic** code: the frontend (`src/**`), shared `main.py` logic, messages, or logging.

- Run on **one** OS. Use whichever is booted; prefer SteamOS, which has the largest user base.
- [ ] Plugin loads; Quick Access Menu opens with no errors
- [ ] Error paths, triggered with stub scripts or forced failures (e.g. enable with the cable unlocked). These are OS-agnostic, so check them **once**, not per OS.
- [ ] One Enable → Eject cycle in Game Mode on one display
- [ ] Activity Logs shows the log for the run that just happened

### Tier 2: Per-OS functional
Use for changes to **OS-specific** code paths: `bin/egpu-*`, `bin/install-*`, `bin/uninstall.sh`, `bin/create-shortcuts`, `assets/services/*`, and the OS branches in `main.py`.

- Run on **each OS whose branch changed**, and only those. Use one display.
- [ ] Enable → Game Mode on the external display → Eject → handheld screen
- [ ] Enable with "DesktopMode on Enable" → Desktop Mode → Eject desktop link → Game Mode
- [ ] Desktop shortcuts work (only if shortcut or desktop-transition code changed)
- [ ] Driver install / reset (only if installer code changed; see [Snapshots](#os-snapshots-for-fast-resets))
- [ ] Reboot with the eGPU active comes back cleanly (only if boot-sync or services changed)

### Tier 3: Full matrix
Required **only** for:
- A **stable release** (all betas since the last stable release are covered by this one pass)
- Changes to display or compositor behavior: gamescope settings, `WLR_DRM_DEVICES` / `KWIN_DRM_DEVICES` / Vulkan / EGL environment variables, DRM device selection, display-manager handling, or the NVIDIA driver version

Matrix: SteamOS, Bazzite, CachyOS × Game Mode, Desktop Mode × ultrawide, 4K TV.

---

## Choosing a tier

The required tier is the **highest** one triggered by any changed file:

| Change touches | Tier |
|---|---|
| Docs only (`README.md`, `*.md`) | 0 |
| `src/**`, `LogViewerModal`, messages, `main.py` shared logic | 0 + 1 |
| `package.json` `@decky/ui` / `@decky/api` bump | 0 + 1 on **Steam client Stable and Beta channels** |
| OS-specific branches in `bin/*`, `main.py`, `assets/services/*` | 0 + 2 (affected OSes) + 1 on one other OS as a regression check |
| `bin/install-nvidia*.sh`, `bin/uninstall.sh` | 0 + 2 on that OS, including install and reset |
| Display, compositor, environment-variable, DRM, or driver-version changes | 0 + 3 |
| Stable release | 0 + 3 |
| AMD vendor branches, `bin/supergfx-*` (Flow laptops) | 0 + community testers (see below) |

## Batching rules
- **Stacked PRs share one hardware pass.** Run the highest required tier once, on the top of the stack, before merging. Don't test each PR separately.
- **Betas (GitHub pre-releases) can ship after Tier 1/2.** Tier 3 is only required before a stable release.
- If a fix is found during a hardware pass, re-run **only** the checks affected by that fix, not the whole tier.

## Writing tests

New behavior in `main.py` or `bin/` needs a Tier 0 test. The tests codify current behavior; if a test exposes a bug, fix the bug in its own change.

### Backend (`tests/python/`)
- `main.py` is never imported from the repo: it creates directories relative to its own location at import time. The `xgm` fixture (`conftest.py`) copies it into `tmp_path/homebrew/plugins/xgmobile-manager/`, imports the copy (with the fake `decky.DECKY_PLUGIN_LOG_DIR` set to the copy's `homebrew/logs/xgmobile-manager`, so `LOG_DIR`, its `activity/` subfolder, stays in `tmp_path`), and points `OS_RELEASE_PATH`, `DMI_PRODUCT_PATH`, `ASUS_WMI_DIR` and `DESKTOP_FLAG_PATH` at a fake tree under `tmp_path/sysroot`.
- Like Decky, the fake `decky` deletes all but the newest 4 `*.log` files at the top of its plugin log dir whenever it's imported (the loop is copied from decky-loader v3.2.10); `test_decky_pruning.py` reloads it to prove our logs survive. For safety it takes that dir from `XGM_FAKE_DECKY_PLUGIN_LOG_DIR`, never from an inherited `DECKY_PLUGIN_LOG_DIR`, and only prunes inside the temp dir.
- `xgm.stub("egpu-enable", "exit 4")` writes a stub script into the copy's `bin/`. `xgm.set_os("cachyos")` and `xgm.set_product("RC71L")` write the fake os-release and DMI files. Run async methods with `xgm.run(...)`.
- `fakes/` holds the stand-ins for Decky's `decky`, `decky_plugin` and `settings` modules.

### Scripts (`tests/bin/`)
- **`$XGM_ROOT` convention.** Every script under test sets `ROOT="${XGM_ROOT:-}"` and prefixes every absolute path with `$ROOT` (`$ROOT/etc/environment`, `$ROOT/sys/devices/...`). `XGM_ROOT` is unset in production, so the paths are unchanged. **Every new absolute path in `bin/` must be `$ROOT`-prefixed; `tests/audit/path-audit.bats` enforces it.** Commands are not prefixed; they are shimmed. Shared helpers live in `bin/xgm-common.sh` (`xgm_dm_service`, `xgm_ro_disable`/`xgm_ro_enable`); scripts source it with `. "$(dirname "$(readlink -f "$0")")/xgm-common.sh"`, and it's audited like the scripts. Literal values that only look like paths (an environment value, log text) go in `tests/bin/ALLOWLIST`, which also lists the scripts that are out of scope or only tested up to their pre-flight checks (`@until` must be the first line those tests never reach).
- **Sandbox helpers** (`helpers/sandbox.bash`). `make_root` (called in `setup`) builds a fake system tree under `$BATS_TEST_TMPDIR/root`. Setters change it: `set_os` (also sets the `display-manager.service` alias: plasmalogin on cachyos, sddm otherwise), `set_dm sddm|plasmalogin|gdm|...|none [dangling]` (only sddm and plasmalogin are accepted by `xgm_dm_service`; anything else falls back to sddm.service with a warning), `set_product`, `set_connected`, `nvidia_driver installed|missing`, `nvidia_configs backup|old|missing`, `egpu_appears nvidia|amd|never`, `egpu_drops yes|no`, `egpu_present`, `set_lspci`, `set_lsmod`, `supergfxd_active`, `enable_supergfxctl`, `no_steamos_readonly`, for the GPU layout `gpu_numbering <iGPU card> <iGPU render> <eGPU card> <eGPU render>` (DRM numbers aren't stable across boots) and `record_egpu_pci [address]` (what `egpu-enable` writes to `$DATA_DIR/egpu_pci_address`), for eject's GPU release `gpu_holders <n|ignore-term|unkillable>` and `module_stuck <module>`, for the primary user `steam_user <name>` and `steam_not_running`, for the boot safety net `no_user_session` and `sync_service_installed`, for the systemd managers' environment `manager_env <system|user> NAME=value...` (seed it), `manager_env_of <system|user>` (read it), `user_manager_down` and `session_ready now|never|<n>|activating:<n>` (when the user's `graphical-session.target` is active), and for the CachyOS installer `installed_kernel <kver> <pkgbase> [version]` (a `usr/lib/modules/<kver>/pkgbase` file, with that version both installed and in the sync database), `pacman_repo <pkg> <version|none>`, `pacman_local <pkg> <version|none>`, `pacman_install_rc <code>` and `nvidia_module_for <kver>`. `run_plugin_script <name> <vendor>` runs a script with the same arguments `main.py` passes, sets bats' `$status`/`$output`, and sets `$LOG` to what the script wrote to its log. `$LOG_DIR` is the sandbox plugin log folder (`homebrew/logs/xgmobile-manager/activity`, the `activity/` subfolder of Decky's `DECKY_PLUGIN_LOG_DIR`, which Decky prunes on every load); `run_script` empties it first unless `KEEP_LOG_DIR=1` (the `migrate-logs` tests seed it). `run_without_helper <name> [args...]` runs a copy of the script from a temp bin dir without `xgm-common.sh` (every sourcing script must exit 9 there).
- **Shims** (`shims/`, plus `shims-optional/` for commands that only exist on some systems: `steamos-readonly` is on `PATH` by default and `no_steamos_readonly` removes it; `supergfxctl` is off until `enable_supergfxctl`). One small script per system command. Each appends `<cmd> <args>` to `$SHIM_LOG`; assert with `assert_called "systemctl stop sddm.service"`, `refute_called "steamos-readonly"` and `assert_called_before`. Behavior is controlled through files in `$SHIM_STATE`, which the setters write. `pacman -Si <pkg>` prints one sync-database record per `pacman_repo` argument (`<version>` or `<repo>=<version>`, in repo priority order; or, for the SteamOS pre-flight, the single `$SHIM_STATE/pacman_version`), with the field labels translated (`Versión`) when the locale is Spanish; set `SANDBOX_LANG` to run a script under another `LANG` (default `C`). `pacman -Q <pkg>` reports what `pacman_local` set, and `pacman -S` exits with `pacman_install_rc` (0 by default). `modinfo nvidia` follows `nvidia_driver` (the running kernel); `modinfo -k <kver> nvidia` succeeds only after `nvidia_module_for <kver>`. `mkinitcpio` only records the call. GPUs are laid out like real sysfs by `helpers/fake_gpu.bash`: a PCI device dir (class `0x030000`), a `sys/bus/pci/devices/<address>` link, and `sys/class/drm/{cardN,renderDN}/device` and `sys/class/graphics/fbN/device` links to it. The iGPU is `0000:08:00.0` (`boot_vga` 1, `card0`/`renderD128`/`fb0` by default). `proc/fb` and `sys/class/vtconsole/vtcon0` hold the CachyOS capture (no fbcon, only the dummy console). `sleep` returns instantly and simulates hotplug: once `egpu_enable` is 1 the eGPU `0000:01:00.0` appears (`boot_vga` 0, `card1`/`renderD129`/`fb1` by default), and for NVIDIA `/dev/nvidia*` and the `sys/module/nvidia*` dirs (`nvidia_drm` with `modeset`/`fbdev` Y and refcnt 50); once it is 0 the PCI device and its nodes disappear. `modprobe` creates (`-a`: one per module) and removes `sys/module/<module>`, and `modprobe -r` fails as "in use" for a `module_stuck` module. `fuser` reports the files in use for the next `gpu_holders` checks until any `fuser -k`; with `ignore-term` until `fuser -k -KILL`; with `unkillable` always. With `-v` it lists a fake holder per file. `systemctl enable`/`disable` track the unit for `systemctl is-enabled`, and `set-environment`/`unset-environment`/`show-environment` track each manager's environment (`--user` is the user manager; after `user_manager_down` every `--user` call fails). `ps` prints the `steam_user` (default `xgmtest`), or nothing after `steam_not_running`, and the fake `etc/passwd` makes `xgmtest` (uid 64999, with a runtime dir under `run/user`) the first regular user with a home dir. The sandbox `PATH` holds only the shims plus a fixed list of coreutils, so an unshimmed system command fails with "command not found" instead of running for real.
- **Safety.** Three layers keep a missed `$ROOT` prefix from touching the host. They reduce the risk; they don't make it impossible:
  1. **Audit gate first.** The path audit (`tests/audit/audit.bash`) runs before any `bin/` script executes: as its own `run-all.sh` step, and in the `setup_file` of every `.bats` file in `tests/bin/` (through `xgm_setup_file`, cached per bats run, with `make_root` as a backstop). New test files must call `xgm_setup_file` in `setup_file`.
  2. **Not root.** `run-all.sh` and every `.bats` file refuse to run as root, so writes to system locations (`/etc`, `/usr`, `/sys`, `/dev`) fail with "permission denied".
  3. **A test user that doesn't exist.** The shims report the primary user as `xgmtest`, so paths built from `$PRIMARY_USER` point at a home directory that can't exist.

  What's left: user-writable locations (`/tmp`, `/var/tmp`, your own home). The in-scope scripts no longer hardcode `/home/deck`, but a new one would be your real home on a SteamOS dev machine. Only the audit gate protects those, so never skip it, and never run the tests with `sudo`. `egpu-enable`'s self-repair block runs `chmod +x` on the plugin's own `bin/` files (the repo, not `$ROOT`), so two guards keep tests away from it: the `chmod` shim only runs the real `chmod` on files inside `$BATS_TEST_TMPDIR` and fails the test otherwise, and `run_script` fails any test whose log shows "Initiating self-repair" unless it sets `ALLOW_SELF_REPAIR=1`.

### Error catalog
Every `(script, code)` in `SCRIPT_ERROR_CATALOG` needs a matching `exit N` in `bin/<script>`; `test_catalog_integrity.py` checks this, and that `LOG_MAP` matches the Activity Logs dropdown and `ActionResult` matches `src/lib/notify.tsx`. Codes that come from `set -e` instead of a literal `exit` must be added to `IMPLICIT_EXITS` in that test.

## Hardware coverage

| Hardware | Maintainer-owned | Covered by |
|---|---|---|
| ROG Ally + NVIDIA XG Mobile (RTX 4090) | ✅ | Maintainer |
| Ultrawide monitor, 4K TV | ✅ | Maintainer |
| SteamOS / Bazzite / CachyOS | ✅ (dual-boot) | Maintainer |
| AMD XG Mobile (6850M XT) | ❌ | Community beta testers |
| NVIDIA XG Mobile (RTX 3080) | ❌ | Community beta testers |
| ROG Flow laptops (supergfxctl) | ❌ | Community beta testers |
| DIY docks (osy XG Mobile Station) | ❌ | Community beta testers |

Changes to paths the maintainer can't test ship as a **beta** with a short tester checklist in the release notes or the related issue.

## OS snapshots for fast resets
Installer and first-run testing needs a "clean" OS. Reinstalling is slow, so use snapshots:
- **CachyOS** (btrfs): take a snapshot right after a fresh install, **without the XG Mobile connected and without NVIDIA drivers**. That state reproduces the "drivers never installed" case. Roll back to it to re-test the installer.
- **Bazzite**: `rpm-ostree rollback` / pinned deployments.
- **SteamOS**: no practical snapshots. Do most iteration on CachyOS/Bazzite and run SteamOS passes less often.

## Tooling

| Tool | Status | Purpose |
|---|---|---|
| `build.sh` | ✅ | Builds `xgmobile-manager.zip` |
| No-hardware test harness (`tests/`) | ✅ | Tier 0 pytest + bats + vitest suites, run in CI via `bash tests/run-all.sh` |
| `bin/migrate-logs` | ✅ | Moves logs older versions left in `~/homebrew/logs` (`xgmobile_manager_*.log`, `xgmobile_*.log`, failed DKMS builds) into the plugin log folder `~/homebrew/logs/xgmobile-manager/activity/` (a subfolder because Decky prunes `*.log` files at the top of its plugin log dir on every load), and updates old desktop shortcuts. Run on every plugin load; idempotent. |
| `deploy.sh` | Planned | Build, copy to the Ally over SSH, restart `plugin_loader` |
| `bin/collect-diagnostics` | Planned | Bundles plugin logs, journal excerpts, `/etc/environment`, `modinfo`/`lspci`, and OS version into one file. Used for test runs and for user bug reports. |

Update this table when a tool lands.
