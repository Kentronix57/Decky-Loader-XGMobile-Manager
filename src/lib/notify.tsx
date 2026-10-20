import { ConfirmModal, showModal } from "@decky/ui";
import { toaster } from "@decky/api";
import { LogViewerModal } from "../components/LogViewerModal";
import { PythonInterop } from "./controllers/PythonInterop";

export type ActionStatus = "success" | "already_installed" | "error";

export interface ActionResult {
  ok: boolean;
  status: ActionStatus;
  code: number | null;
  script: string;
  title: string;
  message: string;
  hint: string;
  log_key: string;
}

const MAX_TOAST_BODY = 120;
const FAILURE_DURATION = 8000;

const truncate = (text: string, max: number = MAX_TOAST_BODY): string =>
  text.length > max ? text.slice(0, max) : text;

export function isActionResult(v: unknown): v is ActionResult {
  return (
    typeof v === "object" &&
    v !== null &&
    typeof (v as ActionResult).ok === "boolean" &&
    typeof (v as ActionResult).message === "string"
  );
}

export function toActionResult(v: unknown, fallbackTitle: string): ActionResult {
  if (isActionResult(v)) return v;

  const base = { code: null, script: "", title: fallbackTitle, hint: "", log_key: "" };

  if (typeof v === "string") {
    if (v === "Success" || v.startsWith("SUCCESS")) {
      return { ...base, ok: true, status: "success", message: `${fallbackTitle} complete.` };
    }
    return { ...base, ok: false, status: "error", message: truncate(v) };
  }

  return { ...base, ok: false, status: "error", message: "No response from the plugin backend." };
}

export function notifyResult(result: ActionResult): void {
  if (result.ok) {
    toaster.toast({ title: result.title, body: result.message });
    return;
  }

  PythonInterop.error(`${result.title}: ${result.message} [${result.script}/${result.code}]`).catch(() => {});

  if (result.hint === "") {
    toaster.toast({ title: result.title, body: result.message, duration: FAILURE_DURATION });
    return;
  }

  showModal(
    <ConfirmModal
      strTitle={result.title}
      strDescription={
        <>
          <div style={{ marginBottom: "8px" }}>{result.message}</div>
          <div style={{ opacity: 0.85 }}>{result.hint}</div>
          {result.script && result.code !== null && (
            <div style={{ marginTop: "8px", fontSize: "11px", opacity: 0.5 }}>
              Error ref: {result.script} / exit {result.code}
            </div>
          )}
        </>
      }
      strOKButtonText={result.log_key ? "View Logs" : "OK"}
      strCancelButtonText="Close"
      onOK={() => {
        if (result.log_key) showModal(<LogViewerModal initialLog={result.log_key} />);
      }}
    />
  );
  toaster.toast({ title: result.title, body: result.message });
}

export function notifyError(title: string, err: unknown, actionDescription: string): void {
  console.error(`${title}:`, err);
  PythonInterop.error(String(err)).catch(() => {});

  toaster.toast({
    title,
    body: truncate(`Couldn't ${actionDescription}: lost connection to the plugin backend.`),
    duration: FAILURE_DURATION,
  });

  showModal(
    <ConfirmModal
      strTitle={title}
      strDescription="Try again in a few seconds. If it keeps failing, reload Decky (Decky settings → General → Reload plugins) or reboot. Open Activity Logs → Python Critical Error Log for details."
      strOKButtonText="View Logs"
      strCancelButtonText="Close"
      onOK={() => {
        showModal(<LogViewerModal initialLog="python" />);
      }}
    />
  );
}
