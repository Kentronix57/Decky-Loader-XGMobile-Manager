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

// The panel's palette. The red matches Reset Driver Environment. `undefined` is neutral: the
// default text colour. Colour is never the only signal; every value keeps its text.
export const GREEN = "#59bf40";
export const AMBER = "#e5a33b";
export const RED = "#ff5555";
export type Color = string | undefined;

export interface StatusLine {
  text: string;
  color: Color;
  dimmed: boolean;
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
  if (!loaded) return { text: "XG Mobile: Checking…", color: undefined, dimmed: true };
  if (gpuStatus.active) return { text: "XG Mobile: Active", color: GREEN, dimmed: false };
  if (gpuStatus.connected) return { text: "XG Mobile: Connected", color: undefined, dimmed: false };
  return { text: "XG Mobile: Not connected", color: RED, dimmed: false };
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

// --- Telemetry (bin/get-gpu-stats) ---

// get-gpu-stats' output. The numeric keys are null when unreadable, and missing from an older backend.
export interface Telemetry {
  temp?: string;
  util?: string;
  vram?: string;
  power?: string;
  temp_c?: number | null;
  util_pct?: number | null;
  vram_mb?: number | null;
  vram_total_mb?: number | null;
  power_w?: number | null;
  power_limit_w?: number | null;
}

export interface TelemetryCell {
  label: string;
  text: string;
  color: Color;
}

function hexToRgb(hex: string): number[] {
  return [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
}

// Linear RGB blend: t = 0 gives `from`, t = 1 gives `to`.
function mix(from: string, to: string, t: number): string {
  const a = hexToRgb(from);
  const b = hexToRgb(to);
  return "#" + a.map((v, i) => Math.round(v + (b[i] - v) * t).toString(16).padStart(2, "0")).join("");
}

// Green up to 50 °C, then green → amber up to 70 °C, amber → red up to 85 °C, red above.
export function tempColor(c: number | null): Color {
  if (c === null) return undefined;
  if (c <= 50) return GREEN;
  if (c < 70) return mix(GREEN, AMBER, (c - 50) / 20);
  if (c < 85) return mix(AMBER, RED, (c - 70) / 15);
  return RED;
}

export function formatTemp(c: number | null): string {
  return c === null ? "--" : `${Math.round(c)} °C`;
}

// GPU load gets no colour: high load is normal.
export function formatUtil(p: number | null): string {
  return p === null ? "--" : `${Math.round(p)} %`;
}

// A limit or total of 0 or less isn't a real one: treat it as unknown.
function known(v: number | null): number | null {
  return v !== null && v > 0 ? v : null;
}

export function formatPower(w: number | null, rawLimit: number | null): string {
  const limit = known(rawLimit);
  if (w === null) return "--";
  return limit === null ? `${w.toFixed(1)} W` : `${w.toFixed(1)} / ${limit.toFixed(0)} W`;
}

// Amber when pinned at the limit (a higher power profile would help).
export function powerColor(w: number | null, rawLimit: number | null): Color {
  const limit = known(rawLimit);
  if (w === null || limit === null) return undefined;
  return w >= 0.95 * limit ? AMBER : undefined;
}

export function formatVram(mb: number | null, rawTotalMb: number | null): string {
  const totalMb = known(rawTotalMb);
  if (mb === null) return "--";
  const gb = (v: number) => (v / 1024).toFixed(1);
  return totalMb === null ? `${gb(mb)} GB` : `${gb(mb)} / ${gb(totalMb)} GB`;
}

// Amber above 85 % of VRAM, red above 95 %.
export function vramColor(mb: number | null, rawTotalMb: number | null): Color {
  const totalMb = known(rawTotalMb);
  if (mb === null || totalMb === null) return undefined;
  const used = mb / totalMb;
  if (used > 0.95) return RED;
  if (used > 0.85) return AMBER;
  return undefined;
}

// The 2×2 grid, in display order. Without the numeric keys (an older backend) each cell shows the
// old string field, uncoloured.
export function telemetryCells(t: Telemetry): TelemetryCell[] {
  const old = (v: string | undefined) => ({ text: v ?? "--", color: undefined });
  const temp = t.temp_c ?? null;
  const util = t.util_pct ?? null;
  const vram = t.vram_mb ?? null;
  const vramTotal = t.vram_total_mb ?? null;
  const power = t.power_w ?? null;
  const powerLimit = t.power_limit_w ?? null;
  return [
    { label: "Temperature", ...("temp_c" in t ? { text: formatTemp(temp), color: tempColor(temp) } : old(t.temp)) },
    { label: "Power Draw", ...("power_w" in t ? { text: formatPower(power, powerLimit), color: powerColor(power, powerLimit) } : old(t.power)) },
    { label: "VRAM Usage", ...("vram_mb" in t ? { text: formatVram(vram, vramTotal), color: vramColor(vram, vramTotal) } : old(t.vram)) },
    { label: "GPU Load", ...("util_pct" in t ? { text: formatUtil(util), color: undefined } : old(t.util)) },
  ];
}
