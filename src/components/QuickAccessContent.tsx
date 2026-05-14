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
import { call, toaster } from "@decky/api";
import { LiveLogViewerModal } from "./LiveLogViewerModal";
import { LogViewerModal } from "./LogViewerModal";

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
  const [hasSupergfxctl, setHasSupergfxctl] = useState<boolean>(false);
  const [deviceType, setDeviceType] = useState<string>("unknown");
  //const [daemonActive, setDaemonActive] = useState<boolean>(true);
  
  // Dynamic State from Backend
  const [gpuStatus, setGpuStatus] = useState({ connected: false, active: false, vendor: "none" });
  const [telemetry, setTelemetry] = useState({ temp: "--", power: "--", vram: "--", util: "--" });
  const [selectedVendor, setSelectedVendor] = useState("nvidia");
  const [osType, setOsType] = useState("steamos");
  const [powerProfile, setPowerProfile] = useState("Unknown");
  const showSleepWarning = gpuStatus.active && selectedVendor === 'nvidia' && (osType.includes('bazzite') || osType === 'cachyos');

  // 1. Initial Load: Fetch Vendor Setting once
  useEffect(() => {
    const init = async () => {
      try {
        const val = await call("get_setting", "gpu_vendor", "nvidia") as string;
        setSelectedVendor(val);
        const ver = await call("get_version") as string;
        if (ver) setPluginVersion(ver);
        const os = await call("get_os_status") as string;
        setOsType(os);
        // call() returns the boolean directly from Python
        const hasSgfx = await call("has_supergfxctl") as boolean;
        setHasSupergfxctl(hasSgfx);
        const device = await call("get_device_type") as string;
        setDeviceType(device);
      } catch (e) { 
        console.error("Init Error:", e); 
      }
    };
    init();
  }, []);

  // 2. The Polling Loop: Only fetches hardware/telemetry
  useEffect(() => {
    const poll = async () => {
      try {
        const currentStatus = await call("get_gpu_status") as any;
        if (currentStatus) setGpuStatus(currentStatus);
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

  const handleAction = async (method: string, label: string) => {
    if (isLoading) return;
    setIsLoading(true);
    setStatusText(label);
    toaster.toast({ title: "XG Mobile", body: `Starting: ${label}...` });

    try {
      const result = await call(method);
      toaster.toast({ title: "XG Mobile", body: `${label} Result: ${result}` });
      const newStatus = await call("get_gpu_status") as any;
      setGpuStatus(newStatus);
    } catch (e) {
      toaster.toast({ title: "Error", body: "Action failed." });
    } finally {
      setIsLoading(false);
      setStatusText("");
    }
  };

  const handleInstall = async () => {
    if (isLoading) return;
    showModal(<LiveLogViewerModal logType="install" />);
    setIsLoading(true);
    setStatusText("Installing");

    try {
      const result = (await call("install_nvidia")) as string;
      if (result.includes("Failed") || result.includes("Error")) {
        toaster.toast({ 
          title: "NVIDIA Setup", 
          body: "Installation failed. Check the logs.", 
          duration: 5000 
        });
      } else {
        toaster.toast({ 
          title: "NVIDIA Setup", 
          body: "Success! Please reboot your device." 
        });
        setNeedsReboot(true);
      }
    } catch (e) {
      toaster.toast({ title: "Error", body: "Plugin communication failed." });
    } finally {
      setIsLoading(false);
    }
  };

  const enableSuperGfxd = async () => {
    if (isLoading) return;
    setIsLoading(true);
    setStatusText("Restarting Daemon");
    toaster.toast({ title: "Flow Controls", body: "Restarting supergfxd..." });

    try {
      const result = await call("restart_supergfxd") as string;
      if (result === "Success") {
        toaster.toast({ title: "Flow Controls", body: "Daemon restarted successfully." });
      } else {
        toaster.toast({ title: "Error", body: result });
      }
    } catch (e) {
      toaster.toast({ title: "Error", body: "Action failed." });
    } finally {
      setIsLoading(false);
      setStatusText("");
    }
  };
  
  const toggleVendor = async (val: boolean) => {
    const newVendor = val ? "nvidia" : "amd";
    setSelectedVendor(newVendor);
    await call("set_setting", "gpu_vendor", newVendor ) as string;
  };

  const onResetClick = () => {
    showModal(
      <ConfirmModal
        strTitle="Reset Driver Environment?"
        strDescription="This will purge the NVIDIA driver stack and all filesystem redirects from SteamOS. Continue?"
        strOKButtonText="Purge & Reset"
        onOK={() => { 
          setTimeout(async () => {
            showModal(<LiveLogViewerModal logType="uninstall" />);
            setIsLoading(true);
            try {
              const result = await call("uninstall_nvidia") as string;
              if (result !== "Success") {
                toaster.toast({ title: "Reset Error", body: result });
              } else {
                toaster.toast({ title: "Success!", body: result });
                setNeedsReboot(true);
              }
            } catch (e) {
              toaster.toast({ title: "Error", body: "Backend unreachable." });
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
            Active Power Profile
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
                const newProfile = option.data;
                setPowerProfile(newProfile);
                await call("set_power_profile", { profile: newProfile });
                toaster.toast({ title: "ASUS Profile", body: `Set to ${newProfile}` });
              }}
            />
          )}
        </PanelSectionRow>
      </PanelSection>

      {/* SECTION 2: Controls */}
      <PanelSection title="Controls">
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
                layout="inline"
                disabled={!gpuStatus.connected || gpuStatus.active || isLoading}
                onClick={() => handleAction("enable_egpu", "Enabling")}
              >
                {gpuStatus.active ? "XG Mobile is Active" : "Enable XG Mobile"}
              </ButtonItem>
            </PanelSectionRow>

            <PanelSectionRow>
              <ButtonItem
                layout="inline"
                disabled={!gpuStatus.active || isLoading}
                onClick={() => handleAction("eject_egpu", "Ejecting")}
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
          </>
        )}
      </PanelSection>

      {/* SECTION 3: Maintenance */}
      <PanelSection title="Advanced">
        {/* Render Install button ONLY on SteamOS */}
        {osType === "steamos" && (
          <PanelSectionRow>
            <ButtonItem
              layout="inline"
              disabled={gpuStatus.active || isLoading}
              onClick={handleInstall} 
            >
              Install NVIDIA Drivers
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
                layout="inline"
                disabled={isLoading}
                onClick={() => handleAction("enable_supergfxctl", "Enabling")}
              >
                Send Supergfxctl Hybrid command (ASUS Flow laptops) - beta
              </ButtonItem>
            </PanelSectionRow>

            <PanelSectionRow>
              <ButtonItem
                layout="inline"
                disabled={isLoading}
                onClick={() => handleAction("eject_supergfxctl", "Ejecting")}
              >
                Send Supergfxctl Integrated command (ASUS Flow laptops) - beta
              </ButtonItem>
            </PanelSectionRow>
          </PanelSection>
        )}

        {/* Universal Debug Tools */}
        <PanelSectionRow>
          <ButtonItem
            layout="inline"
            onClick={async () => {
              const test = await call("get_gpu_status");
              toaster.toast({ title: "Debug", body: JSON.stringify(test) });
            }}
          >
            Check Backend eGPU State - Debug
          </ButtonItem>
        </PanelSectionRow>

        <PanelSectionRow>
          <ButtonItem
            layout="inline"
            onClick={() => showModal(<LogViewerModal />)} 
          >
            View Activity Logs
          </ButtonItem>
        </PanelSectionRow>

        {/* Render Reset button ONLY on SteamOS */}
        {osType === "steamos" && (
          <PanelSectionRow>
            <ButtonItem
              layout="inline"
              disabled={gpuStatus.active || isLoading}
              onClick={onResetClick}
            >
              <span style={{ color: "#ff5555" }}>Reset Driver Environment</span>
            </ButtonItem>
          </PanelSectionRow>
        )}
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
