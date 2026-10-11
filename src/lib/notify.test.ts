import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@decky/ui", () => ({
  ConfirmModal: () => null,
  showModal: vi.fn(),
}));

vi.mock("@decky/api", () => ({
  call: vi.fn(),
  toaster: { toast: vi.fn() },
}));

vi.mock("./controllers/PythonInterop", () => ({
  PythonInterop: { error: vi.fn(() => Promise.resolve()) },
}));

vi.mock("../components/LogViewerModal", () => ({
  LogViewerModal: () => null,
}));

import { showModal } from "@decky/ui";
import { toaster } from "@decky/api";
import { PythonInterop } from "./controllers/PythonInterop";
import { ActionResult, isActionResult, notifyResult, toActionResult } from "./notify";

const result = (overrides: Partial<ActionResult> = {}): ActionResult => ({
  ok: false,
  status: "error",
  code: 4,
  script: "egpu-enable",
  title: "Enable Failed",
  message: "NVIDIA Vulkan configs are missing.",
  hint: "",
  log_key: "enable",
  ...overrides,
});

beforeEach(() => {
  vi.clearAllMocks();
});

describe("isActionResult", () => {
  it("accepts a backend ActionResult", () => {
    expect(isActionResult(result())).toBe(true);
  });

  it.each([null, undefined, "Success", 0, {}, { ok: "yes", message: "x" }, { ok: true }])(
    "rejects %j",
    (value) => {
      expect(isActionResult(value)).toBe(false);
    }
  );
});

describe("toActionResult", () => {
  it("passes a real ActionResult through unchanged", () => {
    const r = result({ hint: "do the thing" });
    expect(toActionResult(r, "XG Mobile")).toBe(r);
  });

  it.each(["Success", "SUCCESS: eGPU enabled"])("maps legacy %j to success", (legacy) => {
    expect(toActionResult(legacy, "XG Mobile")).toEqual({
      ok: true,
      status: "success",
      code: null,
      script: "",
      title: "XG Mobile",
      message: "XG Mobile complete.",
      hint: "",
      log_key: "",
    });
  });

  it("maps any other string to an error with that message", () => {
    const r = toActionResult("ERROR: something broke", "Eject");
    expect(r.ok).toBe(false);
    expect(r.status).toBe("error");
    expect(r.title).toBe("Eject");
    expect(r.message).toBe("ERROR: something broke");
  });

  it("truncates long strings to 120 characters", () => {
    const r = toActionResult("x".repeat(300), "Eject");
    expect(r.message).toHaveLength(120);
  });

  it.each([null, undefined])("maps %j to a no-response error", (value) => {
    const r = toActionResult(value, "Eject");
    expect(r.ok).toBe(false);
    expect(r.status).toBe("error");
    expect(r.message).toBe("No response from the plugin backend.");
  });
});

describe("notifyResult", () => {
  it("ok: one toast, no modal, no error log", () => {
    notifyResult(result({ ok: true, status: "success", title: "XG Mobile", message: "XG Mobile enabled." }));
    expect(toaster.toast).toHaveBeenCalledTimes(1);
    expect(toaster.toast).toHaveBeenCalledWith({ title: "XG Mobile", body: "XG Mobile enabled." });
    expect(showModal).not.toHaveBeenCalled();
    expect(PythonInterop.error).not.toHaveBeenCalled();
  });

  it("failure without a hint: one 8000 ms toast, no modal", () => {
    notifyResult(result());
    expect(toaster.toast).toHaveBeenCalledTimes(1);
    expect(toaster.toast).toHaveBeenCalledWith({
      title: "Enable Failed",
      body: "NVIDIA Vulkan configs are missing.",
      duration: 8000,
    });
    expect(showModal).not.toHaveBeenCalled();
    expect(PythonInterop.error).toHaveBeenCalledWith("Enable Failed: NVIDIA Vulkan configs are missing. [egpu-enable/4]");
  });

  it("failure with a hint: toast plus modal", () => {
    notifyResult(result({ hint: "Run Advanced → Install NVIDIA Drivers." }));
    expect(toaster.toast).toHaveBeenCalledTimes(1);
    expect(toaster.toast).toHaveBeenCalledWith({ title: "Enable Failed", body: "NVIDIA Vulkan configs are missing." });
    expect(showModal).toHaveBeenCalledTimes(1);
  });
});
