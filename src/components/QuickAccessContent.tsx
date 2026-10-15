import React, { useState, useEffect } from "react";
import { 
  ButtonItem, 
  Spinner, 
  showModal, 
  ConfirmModal,
  ToggleField, 
  PanelSection, 
  PanelSectionRow,
  Focusable,
  Dropdown
} from "@decky/ui";
import { call } from "@decky/api";
import { LiveLogViewerModal } from "./LiveLogViewerModal";
import { LogViewerModal } from "./LogViewerModal";
import { isActionResult, notifyError, notifyResult, toActionResult } from "../lib/notify";

// Helper for UI styling
const statsStyle: React.CSSProperties = {
  display: "grid",
  gridTemplateColumns: "1fr 1fr",
  gap: "4px",
  padding: "6px",
  backgroundColor: "rgba(0,0,0,0.2)",
  borderRadius: "4px",
  marginBottom: "10px"
};

export const QuickAccessContent = () => {
  const [needsReboot, setNeedsReboot] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [statusText, setStatusText] = useState("");
  const [pluginVersion, setPluginVersion] = useState("Loading...");
  //const [hasSupergfxctl, setHasSupergfxctl] = useState<boolean>(false);
  const [deviceType, setDeviceType] = useState<string>("unknown");
  //const [daemonActive, setDaemonActive] = useState<boolean>(true);
  
  // Dynamic State from Backend
  const [gpuStatus, setGpuStatus] = useState({ connected: false, active: false, vendor: "none" });
  const [telemetry, setTelemetry] = useState({ temp: "--", power: "--", vram: "--", util: "--" });
  const [selectedVendor, setSelectedVendor] = useState("nvidia");
  const [selectedDesktopMode, setSelectedDesktopMode] = useState("0");
  const [selectedDesktopDefault, setSelectedDesktopDefault] = useState("0");
  const [osType, setOsType] = useState("steamos");
  const [powerProfile, setPowerProfile] = useState("Unknown");
  const [statusError, setStatusError] = useState("");
  const showSleepWarning = gpuStatus.active && selectedVendor === 'nvidia' && osType.includes('bazzite');

  // 1. Initial Load: Fetch Vendor Setting once
  useEffect(() => {
    const init = async () => {
      try {
        const val = await call("get_setting", "gpu_vendor", "nvidia") as string;
        setSelectedVendor(val);
        const desktopmode = await call("get_setting", "desktop_mode", "0") as string;
        setSelectedDesktopMode(desktopmode);
        const desktopdefault = await call("get_setting", "desktop_default", "0") as string;
        setSelectedDesktopDefault(desktopdefault);
        const ver = await call("get_version") as string;
        if (ver) setPluginVersion(ver);
        const os = await call("get_os_status") as string;
        setOsType(os);
        // call() returns the boolean directly from Python
        //const hasSgfx = await call("has_supergfxctl") as boolean;
        //setHasSupergfxctl(hasSgfx);
        const device = await call("get_device_type") as string;
        setDeviceType(device);
      } catch (e) { 
        notifyError("XG Mobile Manager", e, "load plugin settings");
      }
    };
    init();

    // Enable/eject restart the display manager, which can kill this panel before their result
    // arrives (e.g. "Eject was cancelled"). The backend keeps the last failure; show it once.
    const showPendingResult = async () => {
      try {
        const pending = await call("get_pending_result");
        if (isActionResult(pending)) notifyResult(pending);
      } catch (e) {
        console.error("Pending result check failed:", e);
      }
    };
    showPendingResult();
  }, []);

  // 2. The Polling Loop: Only fetches hardware/telemetry
  useEffect(() => {
    const poll = async () => {
      try {
        const currentStatus = await call("get_gpu_status") as any;
        if (currentStatus && typeof currentStatus === "object") {
          setGpuStatus(currentStatus);
          setStatusError(currentStatus.error ?? "");
        }
        if (currentStatus?.active) {
          const stats = await call("get_telemetry") as any;
          if (stats) setTelemetry(stats);
        }
        const prof = await call("get_power_profile") as string;
        setPowerProfile(prof);
      } catch (e) {
        console.error("Poll Error:", e);
      }
    };

    poll(); 
    const interval = setInterval(poll, 3000);
    return () => clearInterval(interval);
  }, []);

  const handleAction = async (method: string, label: string, actionPhrase: string) => {
    if (isLoading) return;
    setIsLoading(true);
    setStatusText(label);

    try {
      if (selectedDesktopMode === "1" && method === "enable_egpu") {
        // A failed flag write is only a warning; the enable still runs.
        const flagRes = toActionResult(await call("set_desktop_transition_flag"), "Desktop Mode");
        if (!flagRes.ok) notifyResult(flagRes);
      }
      const res = toActionResult(await call(method), label);
      notifyResult(res);
      if (method === "enable_egpu" || method === "eject_egpu") {
        // Shown just now: drop the backend's copy so it isn't shown again on the next open.
        await call("get_pending_result").catch(() => undefined);
      }
    } catch (e) {
      notifyError("XG Mobile", e, actionPhrase);
    }

    // Separate try: a failed refresh must never contradict a successful action.
    try {
      const newStatus = await call("get_gpu_status") as any;
      if (newStatus && typeof newStatus === "object") {
        setGpuStatus(newStatus);
        setStatusError(newStatus.error ?? "");
      }
    } catch (e) {
      console.error("Status refresh error:", e);
    } finally {
      setIsLoading(false);
      setStatusText("");
    }
  };

  const handleInstall = async () => {
    if (isLoading) return;
    setIsLoading(true);
    setStatusText("Installing");

    showModal(<LiveLogViewerModal logType="install" />);

    try {
      const res = toActionResult(await call("install_nvidia"), "NVIDIA Install");
      if (res.status !== "success") {
        // Covers both "already_installed" and errors; only a real install earns the reboot prompt.
        notifyResult(res);
      } else {
        showModal(
          <ConfirmModal
            strTitle="Installation Complete"
            strDescription="The NVIDIA drivers were successfully installed. The system must reboot. Reboot now?"
            strOKButtonText="Restart Now"
            onOK={() => { call("reboot_system"); }}
            strCancelButtonText="Restart Later"
          />
        );
      }
    } catch (e) {
      notifyError("NVIDIA Install", e, "install the NVIDIA drivers");
    } finally {
      setIsLoading(false);
      setStatusText("");
    }
  };

  const enableSuperGfxd = async () => {
    if (isLoading) return;
    setIsLoading(true);
    setStatusText("Restarting Daemon");

    try {
      notifyResult(toActionResult(await call("restart_supergfxd"), "Restart supergfxd"));
    } catch (e) {
      notifyError("Flow Controls", e, "restart supergfxd");
    } finally {
      setIsLoading(false);
      setStatusText("");
    }
  };
  const toggleVendor = async (val: boolean) => {
    const prevVendor = selectedVendor;
    const newVendor = val ? "nvidia" : "amd";
    setSelectedVendor(newVendor);
    try {
      await call("set_setting", "gpu_vendor", newVendor ) as string;
    } catch (e) {
      setSelectedVendor(prevVendor);
      notifyError("Settings", e, "save this setting");
    }
  };
  const toggleDesktopMode = async (val: boolean) => {
    const prevDesktopMode = selectedDesktopMode;
    const prevDesktopDefault = selectedDesktopDefault;
    const newDesktopMode = val ? "1" : "0";
    setSelectedDesktopMode(newDesktopMode);
    try {
      await call("set_setting", "desktop_mode", newDesktopMode ) as string;
    } catch (e) {
      setSelectedDesktopMode(prevDesktopMode);
      notifyError("Settings", e, "save this setting");
      return;
    }
    //If they turned off the BootToDesktop, lets turn off DesktopDefault as well. 
    if (newDesktopMode === "0") {
      setSelectedDesktopDefault(newDesktopMode);
      try {
        await call("set_setting", "desktop_default", newDesktopMode ) as string;
      } catch (e) {
        // desktop_mode was saved; only the desktop_default write failed
        setSelectedDesktopDefault(prevDesktopDefault);
        notifyError("Settings", e, "save this setting");
      }
    }
  };
  const toggleDesktopDefault = async (val: boolean) => {
    const prevDesktopDefault = selectedDesktopDefault;
    const newDesktopDefault = val ? "1" : "0";
    setSelectedDesktopDefault(newDesktopDefault);
    try {
      await call("set_setting", "desktop_default", newDesktopDefault ) as string;
    } catch (e) {
      setSelectedDesktopDefault(prevDesktopDefault);
      notifyError("Settings", e, "save this setting");
    }
  };

  const onResetClick = () => {
    showModal(
      <ConfirmModal
        strTitle="Reset Driver Environment?"
        strDescription="This will purge the NVIDIA driver stack and all filesystem redirects from SteamOS. Continue?"
        strOKButtonText="Purge & Reset"
        onOK={() => { 
          setTimeout(async () => {
            setIsLoading(true);
            showModal(<LiveLogViewerModal logType="uninstall" />);
            try {
              const res = toActionResult(await call("uninstall_nvidia"), "Reset Driver Environment");
              if (!res.ok) {
                notifyResult(res);
              } else {
                showModal(
                  <ConfirmModal
                    strTitle="Reset Complete"
                    strDescription="The environment has been purged. You must reboot. Reboot now?"
                    strOKButtonText="Restart Now"
                    onOK={() => { call("reboot_system"); }}
                    strCancelButtonText="Restart Later"
                  />
                );
              }
            } catch (e) {
              notifyError("Reset Driver Environment", e, "reset the driver environment");
            } finally {
              setIsLoading(false);
            }
          }, 200);
        }}
      />
    );
  };

  // If the installation was successful, trap the user in this pure @decky/ui state
  if (needsReboot) {
    return (
      <PanelSection title="Reboot Required">
        <PanelSectionRow>
          <div style={{ marginBottom: "10px", fontSize: "14px" }}>
            The system must reboot to apply changes.
          </div>
        </PanelSectionRow>
        <PanelSectionRow>
          <ButtonItem 
            onClick={async () => {
              await call("reboot_system");
            }}
          >
            Restart Now
          </ButtonItem>
        </PanelSectionRow>
        <PanelSectionRow>
          <ButtonItem 
            onClick={() => setNeedsReboot(false)}
          >
            Restart Later
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
    );
  }
  return (
    <Focusable>
      {/* SECTION 1: Telemetry Dashboard (Only show if connected/active) */}
      {(gpuStatus.active) && (
        <PanelSection title="Performance Monitor">
          <div style={statsStyle}>
            <div>
              <small>Temperature</small>
              <div style={{ fontSize: "1.2em", fontWeight: "bold" }}>{telemetry.temp}</div>
            </div>
            <div>
              <small>Power Draw</small>
              <div style={{ fontSize: "1.2em", fontWeight: "bold" }}>{telemetry.power}</div>
            </div>
            <div>
              <small>VRAM Usage</small>
              <div style={{ fontSize: "1.2em", fontWeight: "bold" }}>{telemetry.vram}</div>
            </div>
            <div>
              <small>GPU Load</small>
              <div style={{ fontSize: "1.2em", fontWeight: "bold" }}>{telemetry.util}</div>
            </div>
          </div>
        </PanelSection>
      )}

      {/* OS WARNING: WRONG BAZZITE IMAGE */}
      {(osType === "bazzite") && (selectedVendor === "nvidia") && (
        <PanelSection title="System Warning">
          <PanelSectionRow>
            <div style={{ color: "#ff5555", fontSize: "14px", marginBottom: "10px" }}>
              <strong>Wrong OS Image Detected!</strong><br/>
              You are running standard Bazzite. To use an NVIDIA eGPU, you MUST install the 'bazzite-deck-nvidia' image. 
              The NVIDIA XG Mobile will not function correctly on this installation. Please install the correct version or select AMD.
            </div>
          </PanelSectionRow>
        </PanelSection>
      )}

      {/* UNIVERSAL ASUS WMI CONTROLS */}
      <PanelSection title="ASUS Hardware Controls">
        <PanelSectionRow>
          <div style={{ marginBottom: "6px", fontSize: "14px", opacity: 0.8 }}>
            ASUS Power Profile (Ally + XG Mobile)
          </div>
          {powerProfile === "Error" || powerProfile === "Unknown" ? (
            <div style={{ color: "#ffab40", fontSize: "12px", fontStyle: "italic", padding: "4px 0" }}>
              Unable to read motherboard WMI policy.
            </div>
          ) : (
            <Dropdown
              selectedOption={powerProfile}
              rgOptions={[
                { data: "Quiet", label: "Quiet" },
                { data: "Balanced", label: "Balanced" },
                { data: "Performance", label: "Performance" }
              ]}
              onChange={async (option: any) => {
                const prevProfile = powerProfile;
                const newProfile = option.data;
                setPowerProfile(newProfile);
                try {
                  const res = toActionResult(await call("set_power_profile", { profile: newProfile }), "ASUS Power Profile");
                  if (!res.ok) setPowerProfile(prevProfile);
                  notifyResult(res);
                } catch (e) {
                  setPowerProfile(prevProfile);
                  notifyError("ASUS Power Profile", e, "change the power profile");
                }
              }}
            />
          )}
          <div style={{ marginTop: "6px", fontSize: "12px", opacity: 0.7 }}>
            Sets the Ally's ASUS profile, which also sets the XG Mobile's power limit (on the RTX 4090: Balanced 120 W, Performance 150 W). Steam's performance setting changes the same profile. Use Steam's TDP slider to limit the Ally CPU. For full XG Mobile power with a cool CPU, pick Performance and cap the CPU with Steam's TDP slider or a TDP plugin.
          </div>
        </PanelSectionRow>
      </PanelSection>

      {/* SECTION 2: Controls */}
      <PanelSection title="Controls">
        {statusError !== "" && (
          <PanelSectionRow>
            <div style={{ color: "#ffab40", fontSize: "12px", fontStyle: "italic", padding: "4px 0" }}>
              Can't read XG Mobile connection state: {statusError} Make sure this is an ASUS device with the asus-nb-wmi driver loaded.
            </div>
          </PanelSectionRow>
        )}
        {isLoading ? (
          <PanelSectionRow>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "center" }}>
              <Spinner />
              <span style={{ marginLeft: "10px" }}>{statusText}...</span>
            </div>
          </PanelSectionRow>
        ) : (
          <>
            <PanelSectionRow>
              <ButtonItem
                layout="below"
                disabled={!gpuStatus.connected || gpuStatus.active || isLoading}
                onClick={() => handleAction("enable_egpu", "Enabling", "enable the XG Mobile")}
              >
                {gpuStatus.active ? "XG Mobile is Active" : "Enable XG Mobile"}
              </ButtonItem>
            </PanelSectionRow>

            <PanelSectionRow>
              <ButtonItem
                layout="below"
                disabled={!gpuStatus.active || isLoading}
                onClick={() => handleAction("eject_egpu", "Ejecting", "eject the XG Mobile")}
              >
                {gpuStatus.active ? "Eject XG Mobile" : "XG Mobile is not Active"}
              </ButtonItem>
            </PanelSectionRow>

            {showSleepWarning && (
              <PanelSectionRow>
                <div style={{
                  backgroundColor: 'rgba(255, 0, 0, 0.15)',
                  border: '1px solid #ff4444',
                  padding: '12px',
                  borderRadius: '6px',
                  color: '#ffdddd',
                  fontSize: '13px',
                  lineHeight: '1.4'
                }}>
                  <b>⚠️ CRITICAL SLEEP WARNING</b><br/>
                  Due to NVIDIA firmware limitations on this OS, putting the device to sleep right now will cause a fatal hardware crash requiring a hard reboot. <br/><br/>
                  <b>You must Eject the eGPU before sleeping.</b>
                </div>
              </PanelSectionRow>
            )}
            <PanelSectionRow>
              <ToggleField
                label="NVIDIA Mode"
                description="Turn off for AMD XG Mobile units"
                // Disable if the hardware is active
                disabled={gpuStatus.active || isLoading}
                checked={selectedVendor === "nvidia"}
                onChange={toggleVendor}
              />
            </PanelSectionRow>
            <PanelSectionRow>
              <ToggleField
                label="DesktopMode on Enable"
                description="Turn on to reboot straight into Desktop Mode when running the Enable. Recommended for 4K and Ultrawide resolutions with NVIDIA GPUs."
                // Disable if the hardware is active
                disabled={gpuStatus.active || isLoading}
                checked={selectedDesktopMode === "1"}
                onChange={toggleDesktopMode}
              />
            </PanelSectionRow>
            <PanelSectionRow>
              <ToggleField
                label="Set Desktop to Default"
                description="Turn on to set Desktop Mode to Default when running the XG Mobile. You MUST run the Eject Desktop Link to revert to GameMode."
                // Disable if the hardware is active
                disabled={gpuStatus.active || isLoading || selectedDesktopMode === "0"}
                checked={selectedDesktopDefault === "1"}
                onChange={toggleDesktopDefault}
              />
            </PanelSectionRow>
          </>
        )}
      </PanelSection>

      {/* SECTION 3: Maintenance */}
      <PanelSection title="Advanced">
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            description="Create Desktop shortcuts for enabling and ejecting the XG Mobile. Run this after selecting Vender type and running Install NVIDIA Drivers if needed."
            disabled={isLoading}
            onClick={() => handleAction("create_desktop_shortcuts", "Creating Shortcuts", "create desktop shortcuts")}
          >
            Create Desktop Shortcuts
          </ButtonItem>
        </PanelSectionRow>
        {/* Render Install button ONLY on SteamOS and CachyOS */}
        {(osType === "steamos" || osType === "cachyos") && (
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              disabled={gpuStatus.active || isLoading}
              onClick={handleInstall} 
            >
              Install NVIDIA Drivers
            </ButtonItem>
          </PanelSectionRow>
        )}
        {/* Render Reset button ONLY on SteamOS */}
        {osType === "steamos" && (
          <PanelSectionRow>
            <ButtonItem
              layout="below"
              disabled={gpuStatus.active || isLoading}
              onClick={onResetClick}
            >
              <span style={{ color: "#ff5555" }}>Reset Driver Environment</span>
            </ButtonItem>
          </PanelSectionRow>
        )}

        {/* SUPERGFXCTL CONTROLS */}
        {deviceType === "laptop" && (//{hasSupergfxctl && (
          <PanelSection title="Flow Laptop Controls">
            <PanelSectionRow>
              <ButtonItem layout="below" onClick={() => enableSuperGfxd()}>
                Restart Supergfxd
              </ButtonItem>
              <ButtonItem
                layout="below"
                disabled={isLoading}
                onClick={() => handleAction("hybrid_supergfxctl", "Switching to Hybrid", "switch to Hybrid mode")}
              >
                Send Supergfxctl Hybrid command - beta
              </ButtonItem>
            </PanelSectionRow>

            <PanelSectionRow>
              <ButtonItem
                layout="below"
                disabled={isLoading}
                onClick={() => handleAction("integrated_supergfxctl", "Switching to Integrated", "switch to Integrated mode")}
              >
                Send Supergfxctl Integrated command - beta
              </ButtonItem>
            </PanelSectionRow>
          </PanelSection>
        )}

        {/* Universal Debug Tools */}
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            onClick={() => showModal(<LogViewerModal />)} 
          >
            View Activity Logs
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title="About">
        <PanelSectionRow>
          <div style={{ display: "flex", justifyContent: "space-between", opacity: 0.6, fontSize: "0.8em" }}>
            <span>Version</span>
            <span>{pluginVersion}</span>
          </div>
        </PanelSectionRow>
        <PanelSectionRow>
          <div style={{ opacity: 0.6, fontSize: "0.8em" }}>
            Created by Kentronix
          </div>
        </PanelSectionRow>
      </PanelSection>
    </Focusable>
  );
};
