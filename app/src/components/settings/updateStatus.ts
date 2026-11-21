import type { UpdateCheckStatus } from "../../stores/useUpdaterStore";

/**
 * What the Updates row in Settings shows and offers for a given updater
 * state. Pure, so the one rule that matters can be tested without a window:
 * WHENEVER an update is known, there is a way to install it from right here.
 *
 * Settings is mounted in both windows, and each window keeps its own updater
 * state. The install dialog (UpdateDialog) is rendered by the widget only.
 * So a check made from the Control Center's Settings found the update,
 * printed "v4.8.0 available" - and offered nothing to click. The only way to
 * install was to find the widget's own Settings and check again there.
 */
export interface UpdateRowView {
  /** Text beside the Check button; null when there is nothing to say yet. */
  label: string | null;
  /** Tone of that text. */
  tone: "neutral" | "available" | "error";
  /** Label of the install button, or null when there is nothing to install. */
  installLabel: string | null;
  /** True while a check, download or install is running: both buttons hold still. */
  busy: boolean;
}

export interface UpdateRowInput {
  status: UpdateCheckStatus;
  /** Version of the update the last check found, if any. */
  version: string | null;
  /** Bytes received so far and the total, while downloading. */
  progress: { downloaded: number; total: number | null } | null;
  /** The updater's message for the last failure, if any. */
  error: string | null;
  /** Which step that failure came from. */
  failedStep: "check" | "install" | null;
}

function percent(progress: UpdateRowInput["progress"]): string {
  if (!progress || !progress.total || progress.total <= 0) return "";
  const value = Math.min(100, Math.max(0, Math.round((progress.downloaded / progress.total) * 100)));
  return ` ${value}%`;
}

export function updateRowView({ status, version, progress, error, failedStep }: UpdateRowInput): UpdateRowView {
  const known = version !== null;
  switch (status) {
    case "checking":
      return { label: "Checking…", tone: "neutral", installLabel: null, busy: true };
    case "up-to-date":
      return { label: "Up to date", tone: "neutral", installLabel: null, busy: false };
    case "available":
      return {
        label: known ? `v${version} available` : "Update available",
        tone: "available",
        installLabel: "Install & Restart",
        busy: false,
      };
    case "downloading":
      return { label: `Downloading…${percent(progress)}`, tone: "neutral", installLabel: null, busy: true };
    case "installing":
      return { label: "Installing…", tone: "neutral", installLabel: null, busy: true };
    case "error":
      // Two different failures share this state. A failed download or
      // install offers a retry. A failed check says so - and an update that
      // an EARLIER check found is still installable, so it stays on offer.
      if (failedStep === "install" && known) {
        return { label: error ? `Install failed: ${error}` : "Install failed", tone: "error", installLabel: "Retry & Restart", busy: false };
      }
      return {
        label: error ? `Check failed: ${error}` : "Check failed",
        tone: "error",
        installLabel: known ? "Install & Restart" : null,
        busy: false,
      };
    default:
      return { label: null, tone: "neutral", installLabel: null, busy: false };
  }
}
