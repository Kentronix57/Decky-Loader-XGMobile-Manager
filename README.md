# XG Mobile Manager for SteamOS

A Decky Loader plugin that brings seamless, UI-driven support for the ASUS ROG XG Mobile eGPU ecosystem to Arch-based handhelds (like the ROG Ally running SteamOS / Bazzite).

This plugin manages the complex hardware handshakes, dynamically compiles and intercepts NVIDIA drivers using safe bind-mount architecture, and injects the necessary Wayland/Vulkan environment variables to make eGPUs work natively inside Steam's Gaming Mode.

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
curl -L https://raw.githubusercontent.com/YourUsername/xgmobile-manager/main/install.sh | bash
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
   git clone https://github.com/YourUsername/xgmobile-manager.git
   cd xgmobile-manager
   ```
2. Install dependencies (requires Node.js and pnpm):
   ```bash
   pnpm install
   ```
3. Build the plugin using the included wrapper script:
   ```bash
   ./build.sh
   ```
4. Transfer the resulting folder to `/home/deck/homebrew/plugins/` on your device and restart the Decky Plugin Loader service.

---

## 🐛 Known Issues
* **Boot Loop after Update:** If you update SteamOS *without* running the Reset script first, the system may try to load orphaned kernel modules. Run the Reset script from recovery or tty to fix.
* **Live Logs "Initializing":** Occasionally the React UI polls faster than the Python backend can open the log file. Close the log viewer and reopen it.

---

## 🏆 Credits
* **Development & Architecture:** Kentronix
* Built using the [@decky/ui](https://github.com/SteamDeckHomebrew/decky-ui) framework.
