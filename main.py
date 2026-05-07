import asyncio
import subprocess
import os
import json
import decky
import decky_plugin
import shutil
from settings import SettingsManager
from typing import TypeVar
from datetime import datetime

Initialized = False
T = TypeVar("T")
LOG_DIR = "/home/deck/homebrew/logs"
ENABLE_LOG = LOG_DIR+"/xgmobile_manager_enable_latest.log"
EJECT_LOG = LOG_DIR+"/xgmobile_manager_eject_latest.log"
REPAIR_LOG = LOG_DIR+"/xgmobile_manager_repair.log"
DEBUG_LOG = LOG_DIR+"/xgmobile_manager_debug.log"
INSTALL_LOG = LOG_DIR+"/xgmobile_manager_install.log"
NUKE_LOG = LOG_DIR+"/xgmobile_manager_nuke.log"

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
    return os.path.dirname(os.path.realpath(__file__))

  async def get_version(self):
    """Reads the version directly from plugin.json."""
    try:
      json_path = os.path.join(self.get_plugin_dir(), "plugin.json")
      
      with open(json_path, 'r') as f:
        data = json.load(f)
        return data.get('version', '0.2.0')
    except Exception as e:
      error(f"Error reading version: {e}")
      return "0.2.0"

  def get_os_type(self):
    """Detects the host OS and validates the Bazzite NVIDIA image."""
    try:
      with open("/etc/os-release", "r") as f:
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

  async def _execute_script(self, script_name, log_path, *args):
    """
    Unified executor that redirects output to a specific log file.
    script_name: name of script in bin/
    log_path: full path to the .log file
    *args: any additional arguments to pass to the script (like vendor)
    """
    script_path = os.path.join(self.get_plugin_dir(), "bin", script_name)
    log(f"Executing: {script_path} with args: {args} Logging to: {log_path}")
        
    if not os.path.exists(script_path):
      error(f"Script not found: {script_path}")
      return f"Error: {script_name} not found"

    clean_env = os.environ.copy()
    clean_env.pop("LD_LIBRARY_PATH", None)

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
            
      return "Success" if process.returncode == 0 else f"Failed (Code {process.returncode})"
    except Exception as e:
      error(f"Execution Error: {str(e)}")
      return f"Error: {str(e)}"

  async def enable_egpu(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()

    if vendor == "nvidia" and os_type == "bazzite":
      return "Error: Wrong OS Image. Please use the bazzite-nvidia-deck image."
    return await self._execute_script("egpu-enable", ENABLE_LOG, vendor, os_type)

  async def eject_egpu(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()
    
    return await self._execute_script("egpu-eject", EJECT_LOG, vendor, os_type)

  async def repair_services(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    return await self._execute_script("repair-services", REPAIR_LOG, vendor)

  async def install_nvidia(self):
    if not self.get_os_type() == "steamos":
      log("SteamOS not detected: Blocking DKMS driver installation.")
      return "Error: SteamOS not detected. NVIDIA Driver install is currently only for SteamOS."
        
    log("SteamOS detected: Starting DKMS driver compilation.")
    return await self._execute_script("install-nvidia.sh", INSTALL_LOG)

  async def mega_nuke(self):
    return await self._execute_script("uninstall.sh", NUKE_LOG)
  
  async def reboot_system(self):
    clean_env = os.environ.copy()
    clean_env.pop("LD_LIBRARY_PATH", None)
    subprocess.run(["sudo", "reboot"], env=clean_env)
    return True

  async def get_power_profile(self):
    try:
      policy_path = "/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy"
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
    try:
      policy_path = "/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy"
      
      # WMI Mapping: 0 = Balanced, 1 = Performance/Turbo, 2 = Quiet
      val_to_write = "0"
      if profile == "Balanced":
        val_to_write = "0"
      elif profile == "Performance":
        val_to_write = "1"
      elif profile == "Quiet":
        val_to_write = "2"
        
      # Decky runs Python as root, so we can just write directly to the sysfs file!
      with open(policy_path, "w") as f:
        f.write(val_to_write)
        
      return "Success"
    except Exception as e:
      error(f"Error setting power profile: {e}")
      return f"Error setting profile: {e}"

  async def get_live_logs(self, log_type="install"):
    """Called by the frontend every 500ms. log_type can be 'repair' or 'install' or 'nuke'."""
    log_map = {
      "enable": ENABLE_LOG,
      "eject": EJECT_LOG,
      "install": INSTALL_LOG,
      "repair": REPAIR_LOG,
      "nuke": NUKE_LOG,
      "debug": DEBUG_LOG
    }
    path = log_map.get(log_type, REPAIR_LOG)
    
    if not os.path.exists(path):
      return ""
    try:
      with open(path, "r") as f:
        return f.read()
    except:
      return "Error reading log file."

  async def get_gpu_status(self):
    status = {"connected": False, "active": False, "vendor": "none"}
    
    try:
      with open(DEBUG_LOG, "a") as dbg:

        conn_path = "/sys/devices/platform/asus-nb-wmi/egpu_connected"
        if os.path.exists(conn_path):
          with open(conn_path, "r") as f:
            val = f.read().strip()
            status["connected"] = (val == "1")
        else:
          return "Error: egpu_connected path missing"

        # Check Active Flag
        enable_path = "/sys/devices/platform/asus-nb-wmi/egpu_enable"
        if os.path.exists(enable_path):
          with open(enable_path, "r") as f:
            val = f.read().strip()
            status["active"] = (val == "1")
        else:
          return "Error: egpu_enable path missing"

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
      with open(DEBUG_LOG, "a") as dbg:
        dbg.write(f"CRITICAL ERROR: {e}\n")
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
    log_map = {
      "repair": REPAIR_LOG,
      "enable": ENABLE_LOG,
      "eject": EJECT_LOG,
      "debug": DEBUG_LOG,
      "install": INSTALL_LOG,
      "nuke": NUKE_LOG
    }
    
    path = log_map.get(log_type, DEBUG_LOG)

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
