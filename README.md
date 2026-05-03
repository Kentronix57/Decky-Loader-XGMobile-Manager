# XG Mobile Manager for SteamOS

> RTX 4090 on a ROG Ally running SteamOS — one-click install/uninstall via Decky Loader.

[![SteamOS Compatible](https://img.shields.io/badge/SteamOS-Compatible-1A9FFF)](https://store.steampowered.com/steamos)
[![Kernel 6.18](https://img.shields.io/badge/kernel-6.18.25--valve1-orange)](https://gitlab.steamos.cloud/jupiter/linux-integration)
[![NVIDIA 595](https://img.shields.io/badge/nvidia--dkms-595.71.05-76B900)](https://www.nvidia.com/Download/index.aspx)
[![CUDA 12.8](https://img.shields.io/badge/CUDA-12.8-76B900)](https://developer.nvidia.com/cuda-downloads)
[![License GPLv3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

![XG Mobile Manager UI](https://raw.githubusercontent.com/Kentronix57/Decky-Loader-XGMobile-Manager/main/assets/mainUI.png)

A Decky Loader plugin that brings seamless, UI-driven support for the ASUS ROG XG Mobile eGPU ecosystem to Arch-based handhelds (like the ROG Ally running SteamOS / Bazzite).

This plugin manages the complex hardware handshakes, dynamically compiles and intercepts NVIDIA drivers using safe bind-mount architecture, and injects the necessary Wayland/Vulkan environment variables to make eGPUs work natively inside Steam's Gaming Mode.

---

## Table of Contents
- [Important Disclaimers & Risks](#️-important-disclaimers--risks)
- [Compatibility Matrix](#-compatibility-matrix)
- [How It Works (Under the Hood)](#️-how-it-works-under-the-hood)
- [Installation](#-installation)
- [How To Use](#-how-to-use)
- [Building From Source](#️-building-from-source)
- [Known Issues](#-known-issues)
- [Support & Troubleshooting](#-support--troubleshooting)
- [Buy Me a Coffee](#-buy-me-a-coffee)
- [Credits](#-credits)

---

## ⚠️ Important Disclaimers & Risks
**Read this before installing. You are modifying core system behaviors.**

* **Beta Software:** This is a community-driven project and is currently in Beta. You are using this at your own risk.
* **Data Corruption Risk:** This plugin modifies the read-only root filesystem, compiles kernel modules via DKMS, and manipulates `/etc/environment`. While it uses a highly protective "Bind Mount" architecture to prevent permanent system bricking, unexpected power loss during installation *could* result in a boot loop requiring a SteamOS reinstall.
* **External Display Limitations:** Due to current upstream limitations in `gamescope` and `mutter` regarding multi-GPU presentation, **4K and 8K resolutions may not function correctly in Gaming Mode**. 1080p and 1440p are generally stable. X11 Desktop Mode provides wider resolution support. Toggle this in the Developer Settings in Steam
* **AMD XG Mobile Untested:** The core development and testing of this plugin was performed using the NVIDIA RTX 4090 XG Mobile. While there is a dedicated code path for the AMD Radeon RX 6850M XT XG Mobile, **it is currently untested by the developer.**

---

## 📊 Compatibility Matrix

| Hardware / OS | Status | Notes |
| :--- | :--- | :--- |
| **ASUS ROG Ally** | 🟢 Tested & Working | Requires SteamOS, Bazzite, or HoloISO. |
| **NVIDIA XG Mobile (4090)** | 🟢 Tested & Working | Full DKMS driver compilation supported. |
| **NVIDIA XG Mobile (3080)** | 🟡 Experimental  | Untested. Uses the same nvidia drivers, but the deviceID is used to insert environment variables for GameMode. |
| **AMD XG Mobile (6850M XT)** | 🟡 Experimental | Untested. Uses native `amdgpu` kernel drivers. |
| **Steam Deck (LCD/OLED)** | 🔴 Incompatible | Lacks the proprietary ASUS XG Mobile port. |
| **Legion Go** | 🔴 Incompatible | Uses standard Thunderbolt/USB4, not XG Mobile. |

---

## ⚙️ How It Works (Under the Hood)
SteamOS is an immutable (read-only) operating system. Traditional NVIDIA driver installations fail because they run out of space on the root partition and get wiped out during every OS update. 

**The Bind Mount Architecture:**
Instead of fighting the OS, this plugin uses "Smart Bind Mounts." When you click Install, it temporarily links the system's root directories (`/usr/lib`, `/var/lib/dkms`) to your massive `/home` partition. The 1.8GB NVIDIA driver payload and compilation tools are downloaded, the kernel modules are built, and the files are safely stored on your user drive. Permanent symlinks are then created. 

**Dynamic Fanging:**
When you enable the eGPU, the plugin "Re-Fangs" the OS by injecting NVIDIA's EGL, Vulkan, and X11 configurations into the system and reloading the display manager. When you eject, it "De-Fangs" the OS, securely ripping the NVIDIA configs out to protect your native AMD APU Handheld Mode.

**Self-Healing:**
If a SteamOS update wipes out the background services, the plugin will automatically detect the missing files and self-repair the next time you enable the XG Mobile.

---

## 📥 Installation

**Prerequisites:**
1. You must have [Decky Loader](https://github.com/SteamDeckHomebrew/decky-loader) installed.
2. You must have at least **4GB of free space** on your `/home` drive and **600MB** on your root (`/`) drive.

**Quick Install:**
Run this single command in your device's terminal (Desktop Mode or via SSH) to download and install the latest release automatically:

```bash
curl -sL "https://raw.githubusercontent.com/Kentronix57/Decky-Loader-XGMobile-Manager/refs/heads/main/bin/install.sh" > /tmp/install.sh && bash /tmp/install.sh
```
*(Note: Restart your Device after installation to ensure the UI loads).*

---

## 📖 How To Use

### The First-Time Setup
1. Plug in the XG Mobile and lock the connector (ensure the LED is white).
2. Open the Quick Access Menu -> XG Mobile Manager.
3. Select your Vendor Mode (NVIDIA or AMD).
4. Click **Install NVIDIA Drivers** (If using NVIDIA).
5. A live terminal will appear. **Do not turn off your device.** This process downloads ~1.8GB of data and compiles the Linux kernel modules. It will take a few minutes.
6. When prompted, **Reboot**.

### Daily Use
* **To Play:** Plug in the XG Mobile, lock it, and click **Enable XG Mobile**. The light on the XG Mobile connector will turn red. The screen will then briefly go black as `gamescope` restarts on the external GPU, please be patient. Some external monitors alternate On/Off during this process.
* **To Disconnect:** Click **Eject XG Mobile**. Wait for the UI to restart and return to the handheld screen and the light on the XG Mobile connector is white before unlocking the cable.

### 🛑 The "SteamOS Update Tax"
Because the NVIDIA drivers are compiled explicitly for the kernel version running at the time of installation, **a SteamOS System Update will break your drivers.**

When there is a SteamOS update available, follow this exact sequence for safety:
1. Open the plugin and click **Reset Driver Environment** (This safely uninstalls the old drivers and restores your native OS architecture).
2. Go to Steam Settings -> System and apply the SteamOS Update.
3. Reboot.
4. Open the plugin and click **Install NVIDIA Drivers** to compile them for the new kernel.

---

## 🛠️ Building From Source
If you wish to contribute or build the plugin from your own development environment:

1. Clone the repository:
   ```bash
   git clone https://github.com/Kentronix57/Decky-Loader-XGMobile-Manager.git
   cd Decky-Loader-XGMobile-Manager
   ```
2. Install dependencies (requires Node.js and pnpm):
   ```bash
   pnpm install
   ```
3. Build the plugin using the included wrapper script:
   ```bash
   ./build.sh
   ```
   Or by using pnpm:
   ```bash
   pnpm build release
   ```
4. Transfer the resulting folder to `/home/deck/homebrew/plugins/` on your device and restart the Decky Plugin Loader service.

---

## 🐛 Known Issues
* **Boot Loop after Update:** If you update SteamOS *without* running the Reset script first, the system may try to load orphaned kernel modules. Run the Reset script from recovery or tty to fix.
* **Live Logs "Initializing":** Occasionally the React UI polls faster than the Python backend can open the log file. Close the log viewer and reopen it.

---

## 🆘 Support & Troubleshooting
**If you encounter a black screen, failed installation, or other bugs:**

Do not panic. Your system can always be recovered using the Reset Driver Environment button, or by running the /home/deck/homebrew/plugins/xgmobile-manager/bin/uninstall.sh script via SSH or TTY.

Check the Issues Tab: See if someone else has already reported your problem on GitHub.

Open a New Issue: If you need help, please open an Issue on GitHub and include:

Your OS and version (e.g., Bazzite, SteamOS 3.5.19)

The exact model of your XG Mobile (4090, 3080, 6850M)

The output of your installation logs. (found at /tmp/xgmobile_manager_install.log. These logs are deleted on a reboot)

Please use GitHub Issues rather than Reddit DMs for technical support so the community can benefit from the solutions!

## ☕ Buy Me a Coffee
This plugin required countless hours of kernel-level debugging, file system reverse-engineering, and risk to my personal hardware to build. I offer it completely free and open-source.

If this tool saved you hours of troubleshooting or finally made your portable eGPU setup viable, consider buying me a coffee or an energy drink to keep the updates coming!
**(Donation Link TBD)**

## 🏆 Credits
* **Development & Architecture:** Kentronix
* Protocol reverse engineering: [osy/XG_Mobile_Station](https://github.com/osy/XG_Mobile_Station)
* asus-linux kernel patches: [asus-linux.org](https://asus-linux.org)
* Valve for shipping the SteamOS kernel with `asus-wmi` + `egpu_enable`
* [Decky Loader](https://decky.xyz/) — the plugin platform
* Stensmir for the idea to use symlinks for nvidia driver installation to avoid needing to re-size partitions. [stesmir/xg-mobile-linux](https://github.com/stensmir/xg-mobile-linux/tree/master).
* Built using the [@decky/ui](https://github.com/SteamDeckHomebrew/decky-ui) framework.
