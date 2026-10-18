import { describe, expect, it } from "vitest";
import {
  AMBER,
  GREEN,
  RED,
  formatPower,
  formatTemp,
  formatUtil,
  formatVram,
  mainButton,
  maintenanceRows,
  powerColor,
  statusLine,
  telemetryCells,
  tempColor,
  vramColor,
} from "./panelLayout";

const active = { connected: true, active: true };
const connected = { connected: true, active: false };
const disconnected = { connected: false, active: false };

const enable = { action: "enable_egpu", statusLabel: "Enabling", actionPhrase: "enable the XG Mobile" };
const eject = { action: "eject_egpu", statusLabel: "Ejecting", actionPhrase: "eject the XG Mobile" };

describe("mainButton", () => {
  it("ejects when the XG Mobile is active", () => {
    expect(mainButton(active, false)).toEqual({ ...eject, label: "Eject XG Mobile", disabled: false });
  });

  it("enables when it is connected but not active", () => {
    expect(mainButton(connected, false)).toEqual({ ...enable, label: "Enable XG Mobile", disabled: false });
  });

  it("asks to connect, disabled, when it is not connected", () => {
    expect(mainButton(disconnected, false)).toEqual({ ...enable, label: "Connect the XG Mobile", disabled: true });
  });

  it("is never clickable while loading", () => {
    expect(mainButton(active, true).disabled).toBe(true);
    expect(mainButton(connected, true).disabled).toBe(true);
    expect(mainButton(disconnected, true).disabled).toBe(true);
  });
});

describe("statusLine", () => {
  it("shows Checking dimmed, in the neutral colour, until the first status poll returns", () => {
    for (const status of [active, connected, disconnected]) {
      expect(statusLine(status, false)).toEqual({ text: "XG Mobile: Checking…", color: undefined, dimmed: true });
    }
  });

  it("shows Active in green", () => {
    expect(statusLine(active, true)).toEqual({ text: "XG Mobile: Active", color: GREEN, dimmed: false });
  });

  it("shows Connected in the neutral colour", () => {
    expect(statusLine(connected, true)).toEqual({ text: "XG Mobile: Connected", color: undefined, dimmed: false });
  });

  it("shows Not connected in red", () => {
    expect(statusLine(disconnected, true)).toEqual({ text: "XG Mobile: Not connected", color: RED, dimmed: false });
  });
});

describe("maintenanceRows", () => {
  it("steamos: shortcuts, install, reset", () => {
    expect(maintenanceRows("steamos", "handheld")).toEqual(["shortcuts", "install", "reset"]);
  });

  it("cachyos: shortcuts, install (no reset)", () => {
    expect(maintenanceRows("cachyos", "handheld")).toEqual(["shortcuts", "install"]);
  });

  it("bazzite: shortcuts only", () => {
    expect(maintenanceRows("bazzite", "handheld")).toEqual(["shortcuts"]);
  });

  it.each(["steamos", "cachyos", "bazzite"])("laptop on %s also gets the Flow controls", (os) => {
    expect(maintenanceRows(os, "laptop")).toContain("flow");
    expect(maintenanceRows(os, "handheld")).not.toContain("flow");
  });
});

describe("palette", () => {
  it("matches the spec (the red is Reset Driver Environment's)", () => {
    expect([GREEN, AMBER, RED]).toEqual(["#59bf40", "#e5a33b", "#ff5555"]);
  });
});

describe("tempColor", () => {
  it("is neutral when unknown", () => {
    expect(tempColor(null)).toBeUndefined();
  });

  it("is green up to 50 °C", () => {
    expect(tempColor(30)).toBe(GREEN);
    expect(tempColor(50)).toBe(GREEN);
  });

  it("blends green → amber between 50 and 70 °C", () => {
    // halfway: (#59bf40 + #e5a33b) / 2
    expect(tempColor(60)).toBe("#9fb13e");
    expect(tempColor(70)).toBe(AMBER);
  });

  it("blends amber → red between 70 and 85 °C", () => {
    // 8/15 of the way from #e5a33b to #ff5555
    expect(tempColor(78)).toBe("#f37949");
  });

  it("is red from 85 °C", () => {
    expect(tempColor(85)).toBe(RED);
    expect(tempColor(95)).toBe(RED);
  });
});

describe("formatTemp / formatUtil", () => {
  it("formats with a unit, or -- when unknown", () => {
    expect(formatTemp(54)).toBe("54 °C");
    expect(formatTemp(null)).toBe("--");
    expect(formatUtil(38)).toBe("38 %");
    expect(formatUtil(null)).toBe("--");
  });
});

describe("formatPower / powerColor", () => {
  it("shows the draw against the limit", () => {
    expect(formatPower(57.5, 150)).toBe("57.5 / 150 W");
    expect(formatPower(57.5, null)).toBe("57.5 W");
    expect(formatPower(null, 150)).toBe("--");
    expect(formatPower(null, null)).toBe("--");
  });

  it("is neutral when either value is unknown", () => {
    expect(powerColor(null, 150)).toBeUndefined();
    expect(powerColor(150, null)).toBeUndefined();
    expect(powerColor(null, null)).toBeUndefined();
  });

  it("is neutral below 95 % of the limit", () => {
    expect(powerColor(57.5, 150)).toBeUndefined();
    expect(powerColor(142.4, 150)).toBeUndefined();
  });

  it("is amber from 95 % of the limit (pinned)", () => {
    expect(powerColor(142.5, 150)).toBe(AMBER);
    expect(powerColor(114, 120)).toBe(AMBER);
    expect(powerColor(149.8, 150)).toBe(AMBER);
    expect(powerColor(151, 150)).toBe(AMBER);
  });
});

describe("formatVram / vramColor", () => {
  it("shows GB with one decimal", () => {
    expect(formatVram(1049, 16384)).toBe("1.0 / 16.0 GB");
    expect(formatVram(1049, null)).toBe("1.0 GB");
    expect(formatVram(null, 16384)).toBe("--");
  });

  it("is neutral when either value is unknown", () => {
    expect(vramColor(null, 16384)).toBeUndefined();
    expect(vramColor(16000, null)).toBeUndefined();
  });

  it("is neutral up to 85 %, amber above", () => {
    expect(vramColor(1049, 16384)).toBeUndefined();
    expect(vramColor(850, 1000)).toBeUndefined();
    expect(vramColor(851, 1000)).toBe(AMBER);
  });

  it("is amber up to 95 %, red above", () => {
    expect(vramColor(950, 1000)).toBe(AMBER);
    expect(vramColor(951, 1000)).toBe(RED);
  });
});

describe("telemetryCells", () => {
  it("formats and colours the numeric keys; GPU load stays neutral", () => {
    expect(telemetryCells({
      temp: "54°C", util: "100%", vram: "1049MB", power: "57.50W",
      temp_c: 54, util_pct: 100, vram_mb: 1049, vram_total_mb: 16376, power_w: 57.5, power_limit_w: 150,
    })).toEqual([
      { label: "Temperature", text: "54 °C", color: tempColor(54) },
      { label: "Power Draw", text: "57.5 / 150 W", color: undefined },
      { label: "VRAM Usage", text: "1.0 / 16.0 GB", color: undefined },
      { label: "GPU Load", text: "100 %", color: undefined },
    ]);
  });

  it("shows -- for null numeric keys", () => {
    const cells = telemetryCells({
      temp: "0°C", util: "0%", vram: "0MB", power: "0W",
      temp_c: null, util_pct: null, vram_mb: null, vram_total_mb: null, power_w: null, power_limit_w: null,
    });
    expect(cells.map((c) => [c.text, c.color])).toEqual([
      ["--", undefined], ["--", undefined], ["--", undefined], ["--", undefined],
    ]);
  });

  it("falls back to the old string fields without the numeric keys (older backend)", () => {
    expect(telemetryCells({ temp: "54°C", util: "38%", vram: "1049MB", power: "57.50W" })).toEqual([
      { label: "Temperature", text: "54°C", color: undefined },
      { label: "Power Draw", text: "57.50W", color: undefined },
      { label: "VRAM Usage", text: "1049MB", color: undefined },
      { label: "GPU Load", text: "38%", color: undefined },
    ]);
    expect(telemetryCells({}).map((c) => c.text)).toEqual(["--", "--", "--", "--"]);
  });
});
