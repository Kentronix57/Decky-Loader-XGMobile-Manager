import { describe, expect, it } from "vitest";
import { mainButton, maintenanceRows, statusLine } from "./panelLayout";

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
  it("shows Checking dimmed until the first status poll returns", () => {
    for (const status of [active, connected, disconnected]) {
      expect(statusLine(status, false)).toEqual({ text: "XG Mobile: Checking…", color: "#8b929a" });
    }
  });

  it("shows Active in green", () => {
    expect(statusLine(active, true)).toEqual({ text: "XG Mobile: Active", color: "#59bf40" });
  });

  it("shows Connected in a neutral color", () => {
    expect(statusLine(connected, true)).toEqual({ text: "XG Mobile: Connected", color: "#dcdedf" });
  });

  it("shows Not connected dimmed", () => {
    expect(statusLine(disconnected, true)).toEqual({ text: "XG Mobile: Not connected", color: "#8b929a" });
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
