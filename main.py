import asyncio
import subprocess
import os
import json
import decky
import decky_plugin
import shutil
import pwd
import time
from settings import SettingsManager
from typing import TypeVar
from datetime import datetime

Initialized = False
T = TypeVar("T")
PLUGIN_DIR = os.path.dirname(os.path.realpath(__file__))
HOMEBREW_DIR = os.path.abspath(os.path.join(PLUGIN_DIR, "../../"))
LOG_DIR = os.path.join(HOMEBREW_DIR, "logs")
DATA_DIR = os.path.join(HOMEBREW_DIR, "data", "xgmobile-manager")
ENABLE_LOG = os.path.join(LOG_DIR, "xgmobile_manager_enable_latest.log")
ENABLEDESKTOP_LOG = os.path.join(LOG_DIR, "xgmobile_manager_desktop_enable_request.log")
EJECT_LOG = os.path.join(LOG_DIR, "xgmobile_manager_eject_latest.log")
EJECTDESKTOP_LOG = os.path.join(LOG_DIR, "xgmobile_manager_desktop_eject_request.log")
TRANSITION_LOG = os.path.join(LOG_DIR, "xgmobile_manager_transition.log")
HYBRID_LOG = os.path.join(LOG_DIR, "xgmobile_manager_supergfxd_hybrid.log")
INTEGRATED_LOG = os.path.join(LOG_DIR, "xgmobile_manager_supergfxd_integrated.log")
DEBUG_LOG = os.path.join(LOG_DIR, "xgmobile_manager_debug.log")
INSTALL_LOG = os.path.join(LOG_DIR, "xgmobile_manager_install.log")
UNINSTALL_LOG = os.path.join(LOG_DIR, "xgmobile_manager_uninstall.log")
SHORTCUTS_LOG = os.path.join(LOG_DIR, "xgmobile_manager_create_shortcuts.log")
SYNC_LOG = os.path.join(LOG_DIR, "xgmobile_manager_boot_sync.log")
PYTHONERROR_LOG = os.path.join(LOG_DIR, "xgmobile_manager_python_crash.log")

OS_RELEASE_PATH = "/etc/os-release"
DMI_PRODUCT_PATH = "/sys/class/dmi/id/product_name"
ASUS_WMI_DIR = "/sys/devices/platform/asus-nb-wmi"
DESKTOP_FLAG_PATH = "/var/tmp/xgmobile_desktop_trigger"

os.makedirs(os.path.join(DATA_DIR, "configs"), exist_ok=True)

LOG_MAP = {
  # key: (path, label shown in LogViewerModal dropdown)
  "enable":        (ENABLE_LOG,        "Enable Log"),
  "enabledesktop": (ENABLEDESKTOP_LOG, "Enable Desktop Link Log"),
  "eject":         (EJECT_LOG,         "Eject Log"),
  "ejectdesktop":  (EJECTDESKTOP_LOG,  "Eject Desktop Link Log"),
  "transition":    (TRANSITION_LOG,    "Desktop Transition Log"),
  "hybrid":        (HYBRID_LOG,        "Supergfx Hybrid Log"),
  "integrated":    (INTEGRATED_LOG,    "Supergfx Integrated Log"),
  "install":       (INSTALL_LOG,       "NVIDIA Install Log"),
  "uninstall":     (UNINSTALL_LOG,     "Reset Environment Log"),
  "shortcuts":     (SHORTCUTS_LOG,     "Install Desktop Shortcuts Log"),
  "sync":          (SYNC_LOG,          "Boot NVIDIA DRM sync Log"),
  "python":        (PYTHONERROR_LOG,   "Python Critical Error Log"),
  "debug":         (DEBUG_LOG,         "Debug Log"),
}

# Per-script copy: log key, success title/message, failure title, action label (for the generic fallback)
SCRIPT_META = {
  "egpu-enable": {
    "log_key": "enable",
    "title": "XG Mobile",
    "message": "XG Mobile enabled.",
    "fail_title": "Enable Failed",
    "action": "Enabling the XG Mobile",
  },
  "egpu-eject": {
    "log_key": "eject",
    "title": "XG Mobile",
    "message": "XG Mobile ejected. It's now safe to unlock the cable.",
    "fail_title": "Eject Failed",
    "action": "Ejecting the XG Mobile",
  },
  "create-shortcuts": {
    "log_key": "shortcuts",
    "title": "Desktop Shortcuts",
    "message": "Enable/Eject shortcuts were added to your Desktop.",
    "fail_title": "Shortcut Creation Failed",
    "action": "Creating desktop shortcuts",
  },
  "supergfx-hybrid": {
    "log_key": "hybrid",
    "title": "Flow Controls",
    "message": "Switched to Hybrid mode. The display session is restarting.",
    "fail_title": "Hybrid Switch Failed",
    "action": "Switching to Hybrid mode",
  },
  "supergfx-integrated": {
    "log_key": "integrated",
    "title": "Flow Controls",
    "message": "Switched to Integrated mode. The display session is restarting.",
    "fail_title": "Integrated Switch Failed",
    "action": "Switching to Integrated mode",
  },
  "install-nvidia.sh": {
    "log_key": "install",
    "title": "NVIDIA Setup",
    "message": "NVIDIA drivers installed.",
    "fail_title": "NVIDIA Install Failed",
    "action": "The NVIDIA driver install",
  },
  "uninstall.sh": {
    "log_key": "uninstall",
    "title": "Reset Driver Environment",
    "message": "Driver environment reset.",
    "fail_title": "Reset Failed",
    "action": "Resetting the driver environment",
  },
}

_SUPERGFX_ERRORS = {
  1: ("supergfxctl failed to switch GPU modes.",
      "Press Restart Supergfxd, then try again. If it still fails, share this log in a GitHub issue."),
  2: ("supergfxctl isn't installed on this system.",
      "Install supergfxctl (asusctl) for your distro, then try again. Bazzite includes it by default."),
}

# script -> exit code -> (message, hint)
SCRIPT_ERROR_CATALOG = {
  "egpu-enable": {
    1: ("XG Mobile isn't locked in. Check the cable latch and try again.",
        "The laptop reports the XG Mobile is not connected. Push the connector fully in, slide the lock switch to locked, wait for the XG Mobile LED, then press Enable again."),
    2: ("NVIDIA driver isn't installed for this kernel.",
        "On SteamOS, run Advanced → Install NVIDIA Drivers and reboot (needed again after every SteamOS kernel update). If your XG Mobile is AMD, turn off NVIDIA Mode."),
    3: ("NVIDIA Vulkan configs are in the old v0.2.0 location.",
        "Run Advanced → Install NVIDIA Drivers to regenerate the Vulkan configs in the new data folder, then reboot and enable again."),
    4: ("NVIDIA Vulkan configs are missing.",
        "Run Advanced → Install NVIDIA Drivers to regenerate the Vulkan configs, then reboot and enable again."),
    5: ("The eGPU never appeared as a display device.",
        "The XG Mobile was switched on but no new GPU showed up in /dev/dri in time. Eject, unlock and re-lock the cable, then try again. If it keeps happening, share the Enable Log on GitHub."),
    6: ("No NVIDIA GPU found on the PCIe bus.",
        "Enable stopped because no NVIDIA device was detected. If your XG Mobile is AMD, turn off NVIDIA Mode. Otherwise re-lock the cable and retry."),
  },
  "egpu-eject": {},
  "install-nvidia.sh": {
    10: ("NVIDIA drivers already match your kernel. No reboot needed.", ""),
    2: ("Unsupported OS. The driver installer is SteamOS-only.",
        "On Bazzite, switch to the bazzite-deck-nvidia image, which includes the drivers. On CachyOS, install your kernel's nvidia-open package (e.g. linux-cachyos-deckify-nvidia-open) plus nvidia-utils and lib32-nvidia-utils."),
    3: ("Kernel headers for your kernel aren't in the SteamOS repo.",
        "Go to Settings → System → Check for Updates, apply any update, reboot, then run Install NVIDIA Drivers again."),
    4: ("Kernel and header versions don't match. Update SteamOS first.",
        "DKMS needs headers that exactly match the running kernel (both versions are in the install log). Apply SteamOS updates and reboot. If you're already up to date, Valve may not have published matching headers yet, so try again after the next update."),
    5: ("Not enough free space on the system partition (/).",
        "The installer needs at least 500 MiB free on the root filesystem. The install log shows how much is free."),
    6: ("Not enough free space on /home (4 GiB needed).",
        "Free up space (for example, uninstall a game), then run Install NVIDIA Drivers again."),
    1: ("The driver build failed and was rolled back.",
        "A step in the install failed and your system was restored. Open the install log, look at the lines just before \"INSTALL FAILED\", and share the log in a GitHub issue."),
  },
  "create-shortcuts": {
    2: ("NVIDIA driver isn't installed, so shortcuts weren't created.",
        "Run Advanced → Install NVIDIA Drivers first, or turn off NVIDIA Mode if your XG Mobile is AMD."),
  },
  "uninstall.sh": {
    1: ("Reset isn't needed on Bazzite or CachyOS.",
        "Your OS manages the NVIDIA drivers and XG Mobile switching natively (via supergfxctl), so there is nothing for this plugin to reset."),
  },
  "supergfx-hybrid": _SUPERGFX_ERRORS,
  "supergfx-integrated": _SUPERGFX_ERRORS,
}

WRONG_BAZZITE_TITLE = "Wrong Bazzite Image"
WRONG_BAZZITE_MESSAGE = "NVIDIA XG Mobile needs the bazzite-deck-nvidia image."
WRONG_BAZZITE_HINT = "Rebase to the bazzite-deck-nvidia image (see the Bazzite docs), or turn off NVIDIA Mode if your XG Mobile is an AMD unit."

def _result(ok, status, title, message, hint="", code=None, script="", log_key=""):
  return {"ok": ok, "status": status, "code": code, "script": script,
          "title": title, "message": message, "hint": hint, "log_key": log_key}

LAUNCH_FAILURE_HINT = "The plugin couldn't launch this script. Open Activity Logs → Python Critical Error Log for details, and share it in a GitHub issue if it keeps happening."
SYSTEMCTL_LAUNCH_FAILURE_HINT = "The plugin couldn't run systemctl to restart supergfxd. Open Activity Logs → Python Critical Error Log for details, and share it in a GitHub issue if it keeps happening."

def _log_python_error(message):
  """Appends a timestamped line to the Python Critical Error Log; never raises."""
  try:
    with open(PYTHONERROR_LOG, "a") as f:
      f.write(f"[{datetime.now().strftime('%H:%M:%S')}] {message}\n")
  except Exception:
    pass

def _short_exc(e, limit=120):
  """One-line, length-capped exception text for toasts and hints."""
  text = (str(e).strip().splitlines() or [type(e).__name__])[0]
  return text[:limit]

def log(txt):
  decky.logger.info(txt)

def warn(txt):
  decky.logger.warn(txt)

def error(txt):
  decky.logger.error(txt)

class Plugin:
  settings: SettingsManager

  # Get the path where the plugin is installed
  def get_plugin_dir(self):
    return PLUGIN_DIR

  async def get_version(self):
    """Reads the version directly from package.json."""
    try:
      json_path = os.path.join(self.get_plugin_dir(), "package.json")
      
      with open(json_path, 'r') as f:
        data = json.load(f)
        return data.get('version', '0.2.0')
    except Exception as e:
      error(f"Error reading version: {e}")
      return "0.2.0"

  async def get_device_type(self):
    try:
      with open(DMI_PRODUCT_PATH, 'r') as f:
        product_name = f.read().strip()
              
      if "RC71L" in product_name or "Ally" in product_name:
        return "handheld"
      elif "Flow" in product_name or "GV" in product_name or "GZ" in product_name:
        return "laptop"
      else:
        return "unknown"
    except Exception as e:
      return "unknown"

  def get_os_type(self):
    """Detects the host OS and validates the Bazzite NVIDIA image."""
    try:
      with open(OS_RELEASE_PATH, "r") as f:
        os_data = f.read().lower()
                
        if "bazzite" in os_data:
          # Check if they actually installed the NVIDIA variant
          if "nvidia" not in os_data:
            return "bazzite"
          return "bazzite-nvidia"
        elif "cachyos" in os_data:
          return "cachyos"
        elif "steamos" in os_data:
          return "steamos"
        else:
          return "unsupported"
    except Exception:
      return "unsupported"

  async def get_os_status(self):
    """Helper to pass the OS type to React on load."""
    return self.get_os_type()

  async def has_supergfxctl(self):
    """Returns True if supergfxctl is installed and in the system PATH."""
    return shutil.which("supergfxctl") is not None

  async def create_desktop_shortcuts(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()
    
    return await self._execute_script("create-shortcuts", SHORTCUTS_LOG, vendor, os_type, LOG_DIR, DATA_DIR)

  async def _execute_script(self, script_name, log_path, *args):
    """
    Unified executor that redirects output to a specific log file.
    script_name: name of script in bin/
    log_path: full path to the .log file
    *args: any additional arguments to pass to the script (like vendor)
    """
    script_path = os.path.join(self.get_plugin_dir(), "bin", script_name)
    log(f"Executing: {script_path} with args: {args} Logging to: {log_path}")

    meta = SCRIPT_META.get(script_name, {
      "log_key": "", "title": script_name, "message": f"{script_name} finished.",
      "fail_title": f"{script_name} Failed", "action": script_name,
    })
    log_key = meta["log_key"]

    if not os.path.exists(script_path):
      error(f"Script not found: {script_path}")
      return _result(False, "error", meta["fail_title"],
                     f"Plugin file missing: bin/{script_name}. Reinstall XG Mobile Manager.",
                     hint="The plugin installation looks incomplete. Reinstall it from the Decky store or the latest GitHub release.",
                     script=script_name, log_key="")

    clean_env = os.environ.copy()
    clean_env.pop("LD_LIBRARY_PATH", None)
    clean_env.pop('http_proxy', None)
    clean_env.pop('https_proxy', None)
    clean_env.pop('ALL_PROXY', None)

    try:
      with open(log_path, "w") as f:
        f.write(f"--- Script Started: {script_name} at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ---\n")
        
        process = await asyncio.create_subprocess_exec(
          'bash', script_path, *args,
          stdout=f, 
          stderr=f, 
          env=clean_env
        )
        
        await process.wait()
    except Exception as e:
      error(f"Execution Error: {str(e)}")
      _log_python_error(f"SCRIPT LAUNCH FAILURE ({script_name}): {str(e)}")
      return _result(False, "error", meta["fail_title"],
                     f"Couldn't start {script_name}: {_short_exc(e)}"[:120],
                     hint=LAUNCH_FAILURE_HINT, script=script_name, log_key="python")

    code = process.returncode
    if code == 0:
      return _result(True, "success", meta["title"], meta["message"],
                     code=0, script=script_name, log_key=log_key)

    entry = SCRIPT_ERROR_CATALOG.get(script_name, {}).get(code)

    if script_name == "install-nvidia.sh" and code == 10:
      message, hint = entry
      return _result(True, "already_installed", meta["title"], message, hint=hint,
                     code=code, script=script_name, log_key=log_key)

    if entry:
      message, hint = entry
    else:
      log_label = LOG_MAP[log_key][1] if log_key in LOG_MAP else "the plugin logs"
      message = f"{meta['action']} failed (exit code {code})."
      hint = f"Open Activity Logs → {log_label} and check the last lines. If you can't tell what went wrong, share that log in a GitHub issue."
    return _result(False, "error", meta["fail_title"], message, hint=hint,
                   code=code, script=script_name, log_key=log_key)

  async def enable_egpu(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()

    if vendor == "nvidia" and os_type == "bazzite":
      return _result(False, "error", WRONG_BAZZITE_TITLE, WRONG_BAZZITE_MESSAGE, hint=WRONG_BAZZITE_HINT)
    return await self._execute_script("egpu-enable", ENABLE_LOG, vendor, os_type, LOG_DIR, DATA_DIR)

  async def eject_egpu(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()
    
    return await self._execute_script("egpu-eject", EJECT_LOG, vendor, os_type, LOG_DIR, DATA_DIR)

  async def watch_eject_request(self):
    request_file = "/tmp/xgmobile_eject_request"
    fallback_log = PYTHONERROR_LOG #"/tmp/xgmobile_python_crash.log"
    
    while True:
      if os.path.exists(request_file):
        # 1. DELETE IMMEDIATELY to prevent infinite error loops
        os.remove(request_file)
        
        try:
          # 2. Grab the variables directly from the backend, no JSON needed!
          vendor = await self.get_setting("gpu_vendor", "nvidia")
          os_type = self.get_os_type()

          # 3. Safe dynamic user resolution
          decky_user = os.environ.get("DECKY_USER")
          target_user = None
        
          if decky_user:
            try: target_user = pwd.getpwnam(decky_user)
            except KeyError: pass
        
          if not target_user:
            try:
              res = subprocess.run(["pgrep", "-x", "steam"], capture_output=True, text=True)
              if res.returncode == 0 and res.stdout.strip():
                pid = res.stdout.strip().split()[0]
                uid = os.stat(f"/proc/{pid}").st_uid
                target_user = pwd.getpwuid(uid)
            except Exception:
              pass
        
          if not target_user:
            for p in pwd.getpwall():
              if 1000 <= p.pw_uid < 65534 and p.pw_dir.startswith('/home/'):
                target_user = p
                break
        
          if not target_user:
            target_user = pwd.getpwnam("deck")
            
          username = target_user.pw_name
          home_dir = target_user.pw_dir
          desktop_log_path = EJECTDESKTOP_LOG #f"{home_dir}/homebrew/logs/xgmobile_desktop_eject_request.log"
        
          def write_log(message):
            with open(desktop_log_path, "a") as f:
              f.write(f"[{datetime.now().strftime('%H:%M:%S')}] {message}\n")

          write_log("-----------------------------------------")
          write_log(f"Desktop Icon triggered Eject for user: {username} | Vendor: {vendor} | OS: {os_type}")
        
          # 4. Use dynamic plugin paths instead of hardcoded strings
          script_path = os.path.join(self.get_plugin_dir(), "bin", "egpu-eject")
          
          sterile_env = {
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin",
            "USER": username,
            "HOME": home_dir
          }

          result = subprocess.run([
            script_path, 
            vendor, os_type, LOG_DIR, DATA_DIR
          ], capture_output=True, text=True, check=False, env=sterile_env)

          desktopdefault = await self.get_setting("desktop_default", "0")
          #if desktopdefault == "1":
          uid = target_user.pw_uid
          write_log(f"Eject Desktop Link detected Desktop Default enabled for : {username}")
          if os_type != "steamos":
            write_log(f"Telling python to wait 5 seconds before sending gamescope command to switch back to GameMode")
            await asyncio.sleep(5)
          write_log(f"Running the command...")
          safe_env = {
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin",
            "USER": username,
            "HOME": home_dir,
            "XDG_RUNTIME_DIR": f"/run/user/{uid}",
            "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{uid}/bus"
          }
          result = subprocess.run(
            ["sudo", "-E", "-u", username, "/usr/bin/steamos-session-select", "gamescope"],
            capture_output=True,
            text=True,
            check=False,
            env=safe_env
          )

          write_log(f"Command exited with code: {result.returncode}")
          if result.stdout: write_log("STDOUT:\n" + result.stdout.strip())
          if result.stderr: write_log("STDERR:\n" + result.stderr.strip())
        
        except Exception as e:
          # Bleed the error to the fallback log, but DO NOT return. Let the loop survive.
          with open(fallback_log, "a") as f:
            f.write(f"[{datetime.now().strftime('%H:%M:%S')}] CRITICAL WATCHER FAILURE: {str(e)}\n")
            
      # Check every 2 seconds
      await asyncio.sleep(2)

  async def watch_enable_request(self):
    request_file = "/tmp/xgmobile_enable_request"
    fallback_log = PYTHONERROR_LOG #"/tmp/xgmobile_python_crash.log"
    
    while True:
      if os.path.exists(request_file):
        # 1. DELETE IMMEDIATELY to prevent infinite error loops
        os.remove(request_file)
        
        try:
          # 2. Grab the variables directly from the backend, no JSON needed!
          vendor = await self.get_setting("gpu_vendor", "nvidia")
          os_type = self.get_os_type()

          # 3. Safe dynamic user resolution
          decky_user = os.environ.get("DECKY_USER")
          target_user = None
        
          if decky_user:
            try: target_user = pwd.getpwnam(decky_user)
            except KeyError: pass
        
          if not target_user:
            try:
              res = subprocess.run(["pgrep", "-x", "steam"], capture_output=True, text=True)
              if res.returncode == 0 and res.stdout.strip():
                pid = res.stdout.strip().split()[0]
                uid = os.stat(f"/proc/{pid}").st_uid
                target_user = pwd.getpwuid(uid)
            except Exception:
              pass
        
          if not target_user:
            for p in pwd.getpwall():
              if 1000 <= p.pw_uid < 65534 and p.pw_dir.startswith('/home/'):
                target_user = p
                break
        
          if not target_user:
            target_user = pwd.getpwnam("deck")
            
          username = target_user.pw_name
          home_dir = target_user.pw_dir
          desktop_log_path = ENABLEDESKTOP_LOG #f"{home_dir}/homebrew/logs/xgmobile_desktop_enable_request.log"
        
          def write_log(message):
            with open(desktop_log_path, "a") as f:
              f.write(f"[{datetime.now().strftime('%H:%M:%S')}] {message}\n")

          write_log("-----------------------------------------")
          write_log(f"Desktop Icon triggered Enable for user: {username} | Vendor: {vendor} | OS: {os_type}")
        
          # 4. Use dynamic plugin paths instead of hardcoded strings
          script_path = os.path.join(self.get_plugin_dir(), "bin", "egpu-enable")
          
          sterile_env = {
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin",
            "USER": username,
            "HOME": home_dir
          }

          result = subprocess.run([
            script_path, 
            vendor, os_type, LOG_DIR, DATA_DIR
          ], capture_output=True, text=True, check=False, env=sterile_env)
        
          write_log(f"Command exited with code: {result.returncode}")
          if result.returncode == 0: 
            desktopmode = "1" #await self.get_setting("desktop_mode", "0")
            if desktopmode == "1":
              desktopdefault = "0" #await self.get_setting("desktop_default", "0")
              uid = target_user.pw_uid
              
              if os_type != "steamos":
                write_log(f"Desktop Link Enable detected Boot-To-Desktop. Waiting 5 seconds for Steam to stabilize...")
                await asyncio.sleep(5)

              write_log(f"Executing OS Desktop Transition...")
              
              safe_env = {
                "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin",
                "USER": username,
                "HOME": home_dir,
                "XDG_RUNTIME_DIR": f"/run/user/{uid}",
                "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{uid}/bus"
              }
              
              if os_type == "steamos" or os_type == "cachyos":
                target_session = "plasma-wayland-persistent" if desktopdefault == "1" else "plasma-wayland"
              else:
                target_session = "plasma-persistent" if desktopdefault == "1" else "plasma"

              write_log(f"Desktop {os_type} detected, running following session select: {target_session}")

              transition_result = subprocess.run(
                ["sudo", "-E", "-u", username, "/usr/bin/steamos-session-select", target_session],
                capture_output=True, text=True, check=False, env=safe_env
              )
              
              write_log(f"Transition Code: {transition_result.returncode}")
              if transition_result.stdout: write_log("STDOUT:\n" + transition_result.stdout.strip())
              if transition_result.stderr: write_log("STDERR:\n" + transition_result.stderr.strip())
          if result.stdout: write_log("STDOUT:\n" + result.stdout.strip())
          if result.stderr: write_log("STDERR:\n" + result.stderr.strip())
        
        except Exception as e:
          # Bleed the error to the fallback log, but DO NOT return. Let the loop survive.
          with open(fallback_log, "a") as f:
            f.write(f"[{datetime.now().strftime('%H:%M:%S')}] CRITICAL WATCHER FAILURE: {str(e)}\n")
            
      # Check every 2 seconds
      await asyncio.sleep(2)

  async def hybrid_supergfxctl(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()

    if vendor == "nvidia" and os_type == "bazzite":
      return _result(False, "error", WRONG_BAZZITE_TITLE, WRONG_BAZZITE_MESSAGE, hint=WRONG_BAZZITE_HINT)
    return await self._execute_script("supergfx-hybrid", HYBRID_LOG, vendor, os_type, LOG_DIR, DATA_DIR)

  async def integrated_supergfxctl(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()
    
    return await self._execute_script("supergfx-integrated", INTEGRATED_LOG, vendor, os_type, LOG_DIR, DATA_DIR)

  async def install_nvidia(self):
    if not self.get_os_type() == "steamos":
      log("SteamOS not detected: Blocking DKMS driver installation.")
      return _result(False, "error", "NVIDIA Install Unavailable",
                     "The plugin's driver installer is SteamOS-only for now.",
                     hint="Bazzite's deck-nvidia image includes the drivers. On CachyOS, install your kernel's nvidia-open package with pacman (automatic install is coming in a future update).")

    log("SteamOS detected: Starting DKMS driver compilation.")
    return await self._execute_script("install-nvidia.sh", INSTALL_LOG, LOG_DIR, DATA_DIR)

  async def uninstall_nvidia(self):
    return await self._execute_script("uninstall.sh", UNINSTALL_LOG, LOG_DIR, DATA_DIR)
  
  async def set_desktop_transition_flag(self):
    try:
      with open(DESKTOP_FLAG_PATH, "w") as f:
        f.write("transition_requested")
      return _result(True, "success", "Desktop Mode", "Desktop Mode switch scheduled.")
    except Exception as e:
      error(f"Error writing desktop transition flag: {e}")
      return _result(False, "error", "Desktop Mode",
                     "Couldn't schedule the Desktop Mode switch. Enabling without it.",
                     hint=f"{_short_exc(e)}. You can switch to Desktop manually from the Power menu.")

  async def check_and_clear_desktop_flag(self):
    flag_path = DESKTOP_FLAG_PATH
    if os.path.exists(flag_path):
      os.remove(flag_path)
      return True
    return False

  async def trigger_desktop_mode(self):
    fallback_log = PYTHONERROR_LOG #"/tmp/xgmobile_python_crash.log"
    
    try:
      # 1. Safe dynamic user resolution
      decky_user = os.environ.get("DECKY_USER")
      target_user = None
        
      if decky_user:
        try: target_user = pwd.getpwnam(decky_user)
        except KeyError: pass
        
      if not target_user:
        try:
          # Use .run() instead of check_output so it doesn't crash if steam is missing
          res = subprocess.run(["pgrep", "-x", "steam"], capture_output=True, text=True)
          if res.returncode == 0 and res.stdout.strip():
            pid = res.stdout.strip().split()[0]
            uid = os.stat(f"/proc/{pid}").st_uid
            target_user = pwd.getpwuid(uid)
        except Exception:
          pass
        
      if not target_user:
        for p in pwd.getpwall():
          if 1000 <= p.pw_uid < 65534 and p.pw_dir.startswith('/home/'):
            target_user = p
            break
        
      if not target_user:
        target_user = pwd.getpwnam("deck") # Absolute last resort
            
      username = target_user.pw_name
      home_dir = target_user.pw_dir
      uid = target_user.pw_uid
      os_type = self.get_os_type()
        
      # Now we have a guaranteed safe home directory to write to
      log_path = TRANSITION_LOG #f"{home_dir}/homebrew/logs/xgmobile_transition.log"
        
      def write_log(message):
        with open(log_path, "a") as f:
          f.write(f"[{datetime.now().strftime('%H:%M:%S')}] {message}\n")

      write_log("-----------------------------------------")
      write_log(f"React triggered OS Desktop Handoff for user: {username}")
      if os_type != "steamos":
        write_log(f"Telling python to wait 5 seconds")
        await asyncio.sleep(5)
      write_log(f"Running the command...")
      #clean_env = os.environ.copy()
      #clean_env.pop("LD_LIBRARY_PATH", None)
        
      #clean_env["USER"] = username
      #clean_env["HOME"] = home_dir
      #clean_env["XDG_RUNTIME_DIR"] = f"/run/user/{uid}"
      #clean_env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{uid}/bus"
        
      safe_env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin",
        "USER": username,
        "HOME": home_dir,
        "XDG_RUNTIME_DIR": f"/run/user/{uid}",
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{uid}/bus"
      }
      desktopdefault = await self.get_setting("desktop_default", "0")

      if os_type == "steamos" or os_type == "cachyos":
        target_session = "plasma-wayland-persistent" if desktopdefault == "1" else "plasma-wayland"
      else:
        target_session = "plasma-wayland-persistent" if desktopdefault == "1" else "plasma"

      write_log(f"Desktop {os_type} detected, running following session select: {target_session}")

      result = subprocess.run(
        ["sudo", "-E", "-u", username, "/usr/bin/steamos-session-select", target_session],
        capture_output=True, text=True, check=False, env=safe_env
      )
      
      write_log(f"Command exited with code: {result.returncode}")
        
      if result.stdout:
        write_log("STDOUT:")
        write_log(result.stdout.strip())
            
      if result.stderr:
        write_log("STDERR (ERRORS):")
        write_log(result.stderr.strip())
            
      return True
        
    except Exception as e:
      # If absolutely everything breaks, bleed the error into /tmp/
      with open(fallback_log, "a") as f:
        f.write(f"[{datetime.now().strftime('%H:%M:%S')}] CRITICAL PYTHON FAILURE: {str(e)}\n")
      return False

  async def reboot_system(self):
    clean_env = os.environ.copy()
    clean_env.pop("LD_LIBRARY_PATH", None)
    subprocess.run(["systemctl", "reboot"], env=clean_env)
    return True

  async def restart_supergfxd(self):
    """Safely enables and restarts the Asus daemon for Flow Laptop users."""
    log("Attempting to enable and restart supergfxd.service...")
    clean_env = os.environ.copy()
    clean_env.pop("LD_LIBRARY_PATH", None)

    if shutil.which("supergfxctl") is None:
      return _result(False, "error", "Flow Controls", "supergfxctl isn't installed on this system.",
                     hint="Install supergfxctl (asusctl) for your distro, then try again. Bazzite includes it by default.")

    try:
      # Chain enable and restart to guarantee boot persistence and immediate application
      process = await asyncio.create_subprocess_exec(
        'sudo', 'bash', '-c', 'systemctl enable supergfxd.service && systemctl restart supergfxd.service',
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=clean_env
      )
      _, stderr = await process.communicate()
    except Exception as e:
      error(f"Error enabling supergfxd: {e}")
      _log_python_error(f"SUPERGFXD RESTART LAUNCH FAILURE: {str(e)}")
      return _result(False, "error", "Flow Controls", f"Couldn't start systemctl: {_short_exc(e)}"[:120],
                     hint=SYSTEMCTL_LAUNCH_FAILURE_HINT, log_key="python")

    code = process.returncode
    if code == 0:
      return _result(True, "success", "Flow Controls", "supergfxd restarted and enabled at boot.", code=0)

    lines = [l.strip() for l in (stderr or b"").decode(errors="replace").splitlines() if l.strip()]
    last_line = lines[-1][:200] if lines else ""
    error(f"supergfxd restart failed (exit {code}): {last_line}")
    return _result(False, "error", "Flow Controls", f"Couldn't restart supergfxd (exit {code}).",
                   hint=f"systemctl reported: \"{last_line}\". Try rebooting, then press Restart Supergfxd again.",
                   code=code)

  async def get_power_profile(self):
    try:
      policy_path = os.path.join(ASUS_WMI_DIR, "throttle_thermal_policy")
      if not os.path.exists(policy_path):
        return "Unknown"
        
      with open(policy_path, "r") as f:
        val = f.read().strip()
        
      # WMI Mapping: 0 = Balanced, 1 = Performance/Turbo, 2 = Quiet
      if val == "0":
        return "Balanced"
      elif val == "1":
        return "Performance"
      elif val == "2":
        return "Quiet"
      else:
        return "Unknown"
    except Exception as e:
      error(f"Error reading power profile: {e}")
      return "Error"

  async def set_power_profile(self, profile: str):
    clean_profile = str(profile).strip().lower()
    log(f"WMI PROFILE RECEIVED FROM UI: '{clean_profile}'")
    
    val_to_write = "0"
    label = "Balanced"
    if "balanced" in clean_profile:
      val_to_write = "0"
    elif "performance" in  clean_profile:
      val_to_write = "1"
      label = "Performance"
    elif "quiet" in clean_profile:
      val_to_write = "2"
      label = "Quiet"

    try:
      policy_path = os.path.join(ASUS_WMI_DIR, "throttle_thermal_policy")
      with open(policy_path, "w") as f:
        f.write(val_to_write)
      return _result(True, "success", "ASUS Power Profile", f"Power profile set to {label}.")
    except Exception as e:
      error(f"Error setting power profile: {e}")
      return _result(False, "error", "ASUS Power Profile", f"Couldn't set the power profile to {label}.",
                     hint=f"The ASUS WMI policy file couldn't be written ({_short_exc(e)}). Make sure the asus-nb-wmi driver is loaded and that Decky is running as root.")

  def _resolve_log_path(self, log_type: str) -> str:
    """Maps a LOG_MAP key to a file. Enable/Eject prefer the vendor log the scripts actually write to."""
    if log_type not in LOG_MAP:
      log_type = "enable"
    if log_type in ("enable", "eject"):
      try:
        vendor = Plugin.settings.getSetting("gpu_vendor", "nvidia")
      except Exception:
        # Plugin.settings doesn't exist until _main has run
        vendor = "nvidia"
      vendor_path = os.path.join(LOG_DIR, f"xgmobile_manager_{log_type}_{vendor}.log")
      if os.path.exists(vendor_path):
        return vendor_path
    return LOG_MAP[log_type][0]

  async def get_live_logs(self, log_type="install"):
    """Called by the frontend every 500ms. log_type is a LOG_MAP key, e.g. 'install' or 'uninstall'."""
    path = self._resolve_log_path(log_type)
    
    if not os.path.exists(path):
      return ""
    try:
      with open(path, "r") as f:
        return f.read()
    except:
      return "Error reading log file."

  async def get_gpu_status(self):
    status = {"connected": False, "active": False, "vendor": "none", "error": ""}
    
    try:
      conn_path = os.path.join(ASUS_WMI_DIR, "egpu_connected")
      if os.path.exists(conn_path):
        with open(conn_path, "r") as f:
          val = f.read().strip()
          status["connected"] = (val == "1")
      else:
        status["error"] = "asus-nb-wmi eGPU interface not found (egpu_connected missing)."
        return status

      # Check Active Flag
      enable_path = os.path.join(ASUS_WMI_DIR, "egpu_enable")
      if os.path.exists(enable_path):
        with open(enable_path, "r") as f:
          val = f.read().strip()
          status["active"] = (val == "1")
      else:
        status["error"] = "asus-nb-wmi eGPU interface not found (egpu_enable missing)."
        return status

      # Vendor check (PCI Bus)
      try:
        # Ask for ANY NVIDIA device on the PCI bus (Vendor ID 10de)
        res = subprocess.check_output(["lspci", "-n", "-d", "10de:"]).decode()
        if "10de:" in res:
          status["vendor"] = "nvidia"
      except:
        if os.path.exists("/dev/dri/card1"):
          status["vendor"] = "amd"

    except Exception as e:
      error(f"CRITICAL PYTHON ERROR in get_gpu_status: {e}")
      status["error"] = f"Status check failed: {e}."
      try:
        with open(DEBUG_LOG, "a") as dbg:
          dbg.write(f"CRITICAL ERROR: {e}\n")
      except Exception:
        pass
      return status

    return status

  async def get_telemetry(self):
    script_path = os.path.join(self.get_plugin_dir(), "bin", "get-gpu-stats")
    
    # 1. Clean environment to ensure nvidia-smi can find its libraries
    clean_env = os.environ.copy()
    clean_env.pop("LD_LIBRARY_PATH", None)

    try:
      result = subprocess.run(
          [script_path],
          capture_output=True,
          text=True,
          env=clean_env
      )
      
      if result.returncode == 0:
          return json.loads(result.stdout)
      else:
          return {"vendor": "none", "temp": "Err", "util": "Err", "vram": "Err", "power": "Err"}
          
    except Exception as e:
      log(f"Telemetry Fetch Error: {e}")
      return {"vendor": "none", "temp": "--", "util": "--", "vram": "--", "power": "--"}

  # --- LOGGING & REPAIR ---

  async def get_latest_logs(self, log_type="enable"):
    """Reads logs for display in a modal."""
    path = self._resolve_log_path(log_type)

    if not os.path.exists(path):
      return f"No log file found at {path}"

    try:
      with open(path, "r") as f:
        return f.read()
    except Exception as e:
      error(f"Error reading {path}: {e}")
      return f"Error reading log file: {str(e)}"

  async def logMessage(self, message, level):
    if level == 0:
      log(message)
    elif level == 1:
      warn(message)
    elif level == 2:
      error(message)

  # Core Plugin methods
  async def read(self) -> None:
    """
    Reads the json from disk
    """
    Plugin.settings.read()

    # TODO: assign your settings to plugin properties here
  
  # TODO: define additional settings setters here

  # Plugin settingsManager wrappers
  async def get_setting(self, key, default: T) -> T:
    """
    Gets the specified setting from the json

    :param key: The key to get
    :param default: The default value
    :return: The value, or default if not found
    """
    return Plugin.settings.getSetting(key, default)

  async def set_setting(self, key, value: T) -> T:
    """
    Sets the specified setting in the json

    :param key: The key to set
    :param value: The value to set it to
    :return: The new value
    """
    Plugin.settings.setSetting(key, value)
    return value
  
  def del_setting(self, key) -> None:
    """
    Deletes the specified setting in the json
    """
    del Plugin.settings.settings[key]
    Plugin.settings.commit()
    pass

  # Asyncio-compatible long-running code, executed in a task when the plugin is loaded
  async def _main(self):
    global Initialized

    if Initialized:
      return

    Initialized = True

    Plugin.settings = SettingsManager(name="settings", settings_directory=os.environ["DECKY_PLUGIN_SETTINGS_DIR"])
    await Plugin.read(self)
    
    asyncio.create_task(self.watch_eject_request())
    asyncio.create_task(self.watch_enable_request())

#    try:
#      # Check if the eGPU survived the reboot and is still active
#      gpu_state = await self.get_gpu_status()
#      vendor = await self.get_setting("gpu_vendor", "nvidia")
#      os_type = self.get_os_type()
#      if gpu_state.get("active") and vendor == "nvidia":
#        log("eGPU detected as active on boot. Running DRM node sync...")
#        await self._execute_script("egpu-sync", SYNC_LOG, vendor, os_type)
#    except Exception as e:
#      error(f"Boot DRM sync failed: {e}")

    log("XGMobile-Manager Backend Initialized.")

  # Function called first during the unload process, utilize this to handle your plugin being removed
  async def _unload(self):
    decky.logger.info("Unloading Plugin.")

  # Function called when the plugin is uninstalled
  async def _uninstall(self):
    decky.logger.info("Uninstalling Plugin.")

  # Migrations that should be performed before entering `_main()`.
  async def _migration(self):
    pass
