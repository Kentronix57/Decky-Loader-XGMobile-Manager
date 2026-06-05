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
#REPAIR_LOG = os.path.join(LOG_DIR, "xgmobile_manager_repair.log")
DEBUG_LOG = os.path.join(LOG_DIR, "xgmobile_manager_debug.log")
INSTALL_LOG = os.path.join(LOG_DIR, "xgmobile_manager_install.log")
UNINSTALL_LOG = os.path.join(LOG_DIR, "xgmobile_manager_uninstall.log")
SHORTCUTS_LOG = os.path.join(LOG_DIR, "xgmobile_manager_create_shortcuts.log")
SYNC_LOG = os.path.join(LOG_DIR, "xgmobile_manager_boot_sync.log")
PYTHONERROR_LOG = os.path.join(LOG_DIR, "xgmobile_manager_python_crash.log")

os.makedirs(os.path.join(DATA_DIR, "configs"), exist_ok=True)

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
      with open('/sys/class/dmi/id/product_name', 'r') as f:
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
      return "Error: Wrong OS Image. Please use the bazzite-nvidia-deck image."
    return await self._execute_script("supergfx-hybrid", HYBRID_LOG, vendor, os_type, LOG_DIR, DATA_DIR)

  async def integrated_supergfxctl(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    os_type = self.get_os_type()
    
    return await self._execute_script("supergfx-integrated", INTEGRATED_LOG, vendor, os_type, LOG_DIR, DATA_DIR)

  async def repair_services(self):
    vendor = await self.get_setting("gpu_vendor", "nvidia")
    return await self._execute_script("repair-services", REPAIR_LOG, vendor)

  async def install_nvidia(self):
    if not self.get_os_type() == "steamos":
      log("SteamOS not detected: Blocking DKMS driver installation.")
      return "Error: SteamOS not detected. NVIDIA Driver install is currently only for SteamOS."
        
    log("SteamOS detected: Starting DKMS driver compilation.")
    #return await self._execute_script("install-nvidia.sh", INSTALL_LOG, LOG_DIR, DATA_DIR)
    res = await self._execute_script("install-nvidia.sh", INSTALL_LOG, LOG_DIR, DATA_DIR)
    if "Code 1" in res:
        return "ALREADY_INSTALLED"
    elif res == "Success":
        return "SUCCESS"
    else:
        return "ERROR"

  async def uninstall_nvidia(self):
    return await self._execute_script("uninstall.sh", UNINSTALL_LOG, LOG_DIR, DATA_DIR)
  
  async def set_desktop_transition_flag(self):
    try:
      with open("/var/tmp/xgmobile_desktop_trigger", "w") as f:
        f.write("transition_requested")
      return "SUCCESS: File Written"
    except Exception as e:
      return f"ERROR: {str(e)}"

  async def check_and_clear_desktop_flag(self):
    flag_path = "/var/tmp/xgmobile_desktop_trigger"
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
    
    try:
      # Chain enable and restart to guarantee boot persistence and immediate application
      process = await asyncio.create_subprocess_exec(
        'sudo', 'bash', '-c', 'systemctl enable supergfxd.service && systemctl restart supergfxd.service',
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=clean_env
      )
      await process.wait()
      
      return "Success" if process.returncode == 0 else f"Failed (Code {process.returncode})"
    except Exception as e:
      error(f"Error enabling supergfxd: {e}")
      return f"Error: {str(e)}"

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
    clean_profile = str(profile).strip().lower()
    log(f"WMI PROFILE RECEIVED FROM UI: '{clean_profile}'")
    
    val_to_write = "0"
    if "balanced" in clean_profile:
      val_to_write = "0"
    elif "performance" in  clean_profile:
      val_to_write = "1"
    elif "quiet" in clean_profile:
      val_to_write = "2"

    try:
      policy_path = "/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy"
      with open(policy_path, "w") as f:
        f.write(val_to_write)
      return "Success"
    except Exception as e:
      error(f"Error setting power profile: {e}")
      return f"Error setting profile: {e}"

  async def get_live_logs(self, log_type="install"):
    """Called by the frontend every 500ms. log_type can be 'repair' or 'install' or 'uninstall'."""
    log_map = {
      "enable": ENABLE_LOG,
      "enabledesktop": ENABLEDESKTOP_LOG,
      "eject": EJECT_LOG,
      "ejectdesktop": EJECTDESKTOP_LOG,
      "transition": TRANSITION_LOG,
      "hybrid": HYBRID_LOG,
      "integrated": INTEGRATED_LOG,
      "install": INSTALL_LOG,
      #"repair": REPAIR_LOG,
      "uninstall": UNINSTALL_LOG,
      "shortcuts": SHORTCUTS_LOG,
      "sync": SYNC_LOG,
      "python": PYTHONERROR_LOG,
      "debug": DEBUG_LOG
    }
    path = log_map.get(log_type, ENABLE_LOG)
    
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
      "enable": ENABLE_LOG,
      "enabledesktop": ENABLEDESKTOP_LOG,
      "eject": EJECT_LOG,
      "ejectdesktop": EJECTDESKTOP_LOG,
      "transition": TRANSITION_LOG,
      "hybrid": HYBRID_LOG,
      "integrated": INTEGRATED_LOG,
      "install": INSTALL_LOG,
      #"repair": REPAIR_LOG,
      "uninstall": UNINSTALL_LOG,
      "shortcuts": SHORTCUTS_LOG,
      "sync": SYNC_LOG,
      "python": PYTHONERROR_LOG,
      "debug": DEBUG_LOG
    }
    
    path = log_map.get(log_type, ENABLE_LOG)

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
