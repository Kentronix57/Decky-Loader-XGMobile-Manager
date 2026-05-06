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
  
  // Dynamic State from Backend
  const [gpuStatus, setGpuStatus] = useState({ connected: false, active: false, vendor: "none" });
  const [telemetry, setTelemetry] = useState({ temp: "--", power: "--", vram: "--", util: "--" });
  const [selectedVendor, setSelectedVendor] = useState("nvidia");
  const [osType, setOsType] = useState("steamos");
  const [powerProfile, setPowerProfile] = useState("Unknown");

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
        if (os === "bazzite-nvidia" ||os === "bazzite" || os === "cachyos") {
          const prof = await call("get_power_profile") as string;
          setPowerProfile(prof);
        }
      } catch (e) { console.error("Init Error:", e); }
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

  const toggleVendor = async (val: boolean) => {
    const newVendor = val ? "nvidia" : "amd";
    setSelectedVendor(newVendor);
    await call("set_setting", "gpu_vendor", newVendor ) as string;
  };

  const onResetClick = () => {
    showModal(
      <ConfirmModal
        strTitle="Reset Driver Environment?"
        strDescription="This will purge the NVIDIA driver stack and all filesystem redirects. Continue?"
        strOKButtonText="Purge & Reset"
        onOK={() => { 
          setTimeout(async () => {
            // 1. Open the viewer (logType="nuke" must match main.py)
            showModal(<LiveLogViewerModal logType="nuke" />);
             
            setIsLoading(true);
            try {
              const result = await call("mega_nuke") as string;
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
            Reboot Later
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

      {/* ASUS CONTROLS (Only visible on supported OS) */}
      {(osType === "bazzite" || osType === "bazzite-nvidia" || osType === "cachyos") && (
        <PanelSection title="ASUS Hardware Controls">
          <PanelSectionRow>
            <Dropdown
              strDefaultLabel="Power Profile"
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
          </PanelSectionRow>
        </PanelSection>
      )}

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
                {gpuStatus.active ? "Eject XG Mobile (Handheld)" : "XG Mobile is not Active"}
              </ButtonItem>
            </PanelSectionRow>
          </>
        )}
      </PanelSection>

      {/* SECTION 3: Maintenance */}
      <PanelSection title="Advanced">
        <PanelSectionRow>
          <ButtonItem
            layout="inline"
            disabled={gpuStatus.active || isLoading}
            onClick={handleInstall} 
          >
            Install NVIDIA drivers (SteamOS Only)
          </ButtonItem>
        </PanelSectionRow>

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

        <PanelSectionRow>
          <ButtonItem
            layout="inline"
            disabled={gpuStatus.active || isLoading}
            onClick={onResetClick}
          >
            <span style={{ color: "#ff5555" }}>Reset Driver Environment (SteamOS Only)</span>
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
