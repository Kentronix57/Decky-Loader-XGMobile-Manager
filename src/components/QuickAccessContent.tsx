import React, { useState, useEffect } from "react";
import { 
  ButtonItem, 
  Spinner, 
  showModal, 
  ConfirmModal,
  ToggleField, 
  PanelSection, 
  PanelSectionRow,
  Focusable
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
  const [isLoading, setIsLoading] = useState(false);
  const [statusText, setStatusText] = useState("");
  
  // Dynamic State from Backend
  const [gpuStatus, setGpuStatus] = useState({ connected: false, active: false, vendor: "none" });
  const [telemetry, setTelemetry] = useState({ temp: "--", power: "--", vram: "--", util: "--" });
  const [selectedVendor, setSelectedVendor] = useState("nvidia");

  // 1. Initial Load: Fetch Vendor Setting once
  useEffect(() => {
    const init = async () => {
      try {
        const val = await call("get_setting", "gpu_vendor", "nvidia") as string;
        setSelectedVendor(val);
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
            Install NVIDIA drivers
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
            <span style={{ color: "#ff5555" }}>Reset Driver Environment</span>
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title="About">
        <PanelSectionRow>
          <div style={{ display: "flex", justifyContent: "space-between", opacity: 0.6, fontSize: "0.8em" }}>
            <span>Version</span>
            <span>0.1.0</span>
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
