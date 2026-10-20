# XG Mobile Manager

Decky Loader plugin for the ASUS ROG XG Mobile eGPU on SteamOS, Bazzite and CachyOS. The frontend is `src/` (React, `@decky/ui`). The backend is `main.py`. The hardware/OS work happens in the bash scripts in `bin/`.

## Testing (required for every plan and feature)
Read [TESTING.md](TESTING.md) before planning or implementing any change.

Run `bash tests/run-all.sh` before any hardware testing. New behavior in `main.py` or `bin/` needs a Tier 0 test.

- Every plan must include a **Test Plan** section that names:
  - the required tier(s), using TESTING.md "Choosing a tier"
  - which OSes, modes and displays need a hardware pass, and why
  - which checks are covered by Tier 0 automation instead of hardware
- Hardware time is the scarcest resource: one maintainer, 3 OSes, multiple displays. Prefer adding Tier 0 tests over hardware checklist items, and batch stacked work into one hardware pass.
- Flag any change touching hardware the maintainer doesn't own (AMD XG Mobile, RTX 3080 XG Mobile, Flow laptops) as needing community beta testers.
