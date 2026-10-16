// Pure layout decisions for the Quick Access panel, kept out of the component so they can be tested.

export interface GpuStatus {
  connected: boolean;
  active: boolean;
}

export type MainAction = "enable_egpu" | "eject_egpu";

export interface MainButton {
  action: MainAction;
  label: string;
  disabled: boolean;
}

export interface StatusLine {
  text: string;
  color: string;
}

export type MaintenanceRow = "shortcuts" | "install" | "reset" | "flow";

// One main button: Eject while active, otherwise Enable (only once the XG Mobile is connected).
export function mainButton(gpuStatus: GpuStatus, isLoading: boolean): MainButton {
  if (gpuStatus.active) {
    return { action: "eject_egpu", label: "Eject XG Mobile", disabled: isLoading };
  }
  if (!gpuStatus.connected) {
    return { action: "enable_egpu", label: "Connect the XG Mobile", disabled: true };
  }
  return { action: "enable_egpu", label: "Enable XG Mobile", disabled: isLoading };
}

export function statusLine(gpuStatus: GpuStatus): StatusLine {
  if (gpuStatus.active) return { text: "XG Mobile: Active", color: "#59bf40" };
  if (gpuStatus.connected) return { text: "XG Mobile: Connected", color: "#dcdedf" };
  return { text: "XG Mobile: Not connected", color: "#8b929a" };
}

// The rows inside "Setup & Maintenance", in display order.
export function maintenanceRows(osType: string, deviceType: string): MaintenanceRow[] {
  const rows: MaintenanceRow[] = ["shortcuts"];
  // Install NVIDIA Drivers: SteamOS and CachyOS only
  if (osType === "steamos" || osType === "cachyos") rows.push("install");
  // Reset Driver Environment: SteamOS only
  if (osType === "steamos") rows.push("reset");
  // Flow laptops (supergfxctl)
  if (deviceType === "laptop") rows.push("flow");
  return rows;
}
