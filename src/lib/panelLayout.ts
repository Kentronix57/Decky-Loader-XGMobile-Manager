// Pure layout decisions for the Quick Access panel, kept out of the component so they can be tested.

export interface GpuStatus {
  connected: boolean;
  active: boolean;
}

export type MainAction = "enable_egpu" | "eject_egpu";

export interface MainButton {
  action: MainAction;
  statusLabel: string;
  actionPhrase: string;
  label: string;
  disabled: boolean;
}

const ENABLE = { action: "enable_egpu", statusLabel: "Enabling", actionPhrase: "enable the XG Mobile" } as const;
const EJECT = { action: "eject_egpu", statusLabel: "Ejecting", actionPhrase: "eject the XG Mobile" } as const;

export interface StatusLine {
  text: string;
  color: string;
}

export type MaintenanceRow = "shortcuts" | "install" | "reset" | "flow";

// One main button: Eject while active, otherwise Enable (only once the XG Mobile is connected).
export function mainButton(gpuStatus: GpuStatus, isLoading: boolean): MainButton {
  if (gpuStatus.active) {
    return { ...EJECT, label: "Eject XG Mobile", disabled: isLoading };
  }
  if (!gpuStatus.connected) {
    return { ...ENABLE, label: "Connect the XG Mobile", disabled: true };
  }
  return { ...ENABLE, label: "Enable XG Mobile", disabled: isLoading };
}

// Until the first status poll returns, `loaded` is false and the state is unknown.
export function statusLine(gpuStatus: GpuStatus, loaded: boolean): StatusLine {
  if (!loaded) return { text: "XG Mobile: Checking…", color: "#8b929a" };
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
