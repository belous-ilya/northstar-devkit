import { asArray } from "../../../lib/arrays";
import type { Catalog, CatalogItem, WifiMeasureReport, WifiPing, WifiStatus } from "../../../lib/types";

/**
 * Everything the WiFi tray decides, as pure functions over what the sidecar
 * reported - so the wording and the thresholds are unit-tested and the
 * component only lays things out.
 */

export type Tone = "success" | "warning" | "danger" | "neutral" | "accent";

/** "n/a" for anything that was not measured: a number is never invented. */
export const NOT_AVAILABLE = "n/a";

/**
 * A signal percentage in a word. The bottom threshold is the one the
 * diagnosis uses for its "weak signal" finding (40), so the badge and the
 * finding can never disagree.
 */
export function signalQuality(percent: number | null | undefined): { label: string; tone: Tone } {
  if (percent === null || percent === undefined || !Number.isFinite(percent)) return { label: NOT_AVAILABLE, tone: "neutral" };
  if (percent >= 75) return { label: "Excellent", tone: "success" };
  if (percent >= 55) return { label: "Good", tone: "success" };
  if (percent >= 40) return { label: "Fair", tone: "warning" };
  return { label: "Weak", tone: "danger" };
}

export function formatMs(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return NOT_AVAILABLE;
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ms`;
}

export function formatMbps(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return NOT_AVAILABLE;
  return `${Math.round(value)} Mbps`;
}

/** "5 GHz, channel 161" - or whichever half Windows reported. */
export function formatBand(status: Pick<WifiStatus, "Band" | "Channel">): string {
  const parts: string[] = [];
  if (status.Band) parts.push(status.Band);
  if (status.Channel > 0) parts.push(`channel ${status.Channel}`);
  return parts.length > 0 ? parts.join(", ") : NOT_AVAILABLE;
}

/**
 * One line for a ping measurement. Total loss is "no reply", not a latency:
 * plenty of routers ignore ping while the connection through them works,
 * and the findings below the numbers say which case it is.
 */
export function formatPing(ping: WifiPing | null | undefined): string {
  if (!ping) return "not measured";
  if (ping.LossPct >= 100 || ping.AverageMs === null) return "no reply to ping";
  const loss = ping.LossPct > 0 ? `, ${ping.LossPct}% lost` : "";
  const jitter = ping.JitterMs !== null ? `, jitter ${formatMs(ping.JitterMs)}` : "";
  return `${formatMs(ping.AverageMs)}${jitter}${loss}`;
}

/** The headline of the status block. */
export function describeConnection(status: WifiStatus | undefined): { title: string; detail: string | null; connected: boolean } {
  if (!status) return { title: "Checking…", detail: null, connected: false };
  if (!status.AdapterPresent) return { title: "No WiFi adapter", detail: "This PC has no wireless adapter that Windows reports.", connected: false };
  if (!status.Connected) {
    return {
      title: "Not connected",
      detail: status.InterfaceAlias ? `${status.InterfaceAlias} is not connected to a network.` : null,
      connected: false,
    };
  }
  if (status.DetailsHidden || !status.Ssid) {
    return {
      title: "Connected",
      detail:
        "Windows is not saying which network or how strong the signal is. That is what it does while Location is off: Settings > Privacy & security > Location.",
      connected: true,
    };
  }
  return { title: status.Ssid, detail: null, connected: true };
}

const ACTION_WORDS: Record<string, string> = {
  FlushDns: "clear the DNS cache",
  RestoreAutoDns: "put DNS back to automatic",
  SwitchDns: "switch DNS to a faster server",
  RenewLease: "renew this PC's address",
  RestartAdapter: "restart the WiFi adapter",
  ResetStack: "reset the network stack",
};

/**
 * What the Fix button would do after this measurement, in words. The codes
 * are the diagnosis's own (Get-DevKitWifiDiagnosis); an unknown one is shown
 * as it came rather than dropped, so a new fix never goes unmentioned.
 */
export function describeFixPlan(report: Pick<WifiMeasureReport, "Actions" | "BestDns" | "Healthy" | "Findings">): string {
  const actions = asArray(report.Actions);
  if (actions.length === 0) {
    if (report.Healthy) return "Nothing to fix.";
    return "Nothing here can be fixed by a setting on this PC.";
  }
  const words = actions.map((code) => {
    if (code === "SwitchDns" && report.BestDns?.Name) return `switch DNS to ${report.BestDns.Name}`;
    return ACTION_WORDS[code] ?? code;
  });
  const list = words.length === 1 ? words[0] : `${words.slice(0, -1).join(", ")} and ${words[words.length - 1]}`;
  return `WiFi Fix would ${list}.`;
}

/** Worst finding first: the tray leads with what matters. */
export function sortFindings<T extends { Severity: string }>(findings: readonly T[]): T[] {
  const rank: Record<string, number> = { error: 0, warn: 1, info: 2 };
  return [...findings].sort((a, b) => (rank[a.Severity] ?? 3) - (rank[b.Severity] ?? 3));
}

export function findingTone(severity: string): Tone {
  if (severity === "error") return "danger";
  if (severity === "warn") return "warning";
  return "neutral";
}

export type WifiActionId = "fix" | "fast" | "deep" | "undoDns";

export interface WifiAction {
  id: WifiActionId;
  /** Short text for the button. */
  button: string;
  /** The catalog's own name and explanation, for the confirmation. */
  label: string;
  help: string;
  script: string;
  args: string[];
  caution: boolean;
}

const WIFI_FOLDER = "wifi";

/** staticArgs -> script arguments, by the same rule the run dialog and the CLI use. */
function staticArguments(item: CatalogItem): string[] {
  const args: string[] = [];
  for (const [key, value] of Object.entries(item.staticArgs ?? {})) {
    if (value === true) args.push(`-${key}`);
    else if (value !== false && value !== null && value !== undefined) args.push(`-${key}`, String(value));
  }
  return args;
}

const has = (item: CatalogItem, flag: string) => item.staticArgs?.[flag] === true;

/**
 * The tray's fix buttons, taken from the catalog rather than written out
 * here: the script, its arguments, the caution flag and the explanation all
 * come from tools/wifi/_module.psd1, so the tray cannot drift from what the
 * Control Center runs. Each button is recognised by what it does (which
 * script, which switch), not by its position or its label. One that the
 * catalog does not offer is simply not returned - the tray shows no button
 * for it rather than one that cannot work.
 */
export function wifiActionsFromCatalog(catalog: Catalog | undefined): WifiAction[] {
  const module = asArray(catalog?.modules).find((m) => m.folder === WIFI_FOLDER);
  const items = asArray(module?.items);
  const optimize = items.filter((i) => i.script === "WiFi-Optimize.ps1");
  const pick: [WifiActionId, string, CatalogItem | undefined][] = [
    [
      "fix",
      "Fix",
      optimize.find((i) => !has(i, "DiagnoseOnly") && !has(i, "Deep") && !has(i, "RestoreDns") && !has(i, "DryRun")),
    ],
    ["fast", "Fix (fast)", items.find((i) => i.script === "WiFi-FastMode.ps1")],
    ["deep", "Deep reset", optimize.find((i) => has(i, "Deep"))],
    ["undoDns", "Undo DNS change", optimize.find((i) => has(i, "RestoreDns"))],
  ];
  const actions: WifiAction[] = [];
  for (const [id, button, item] of pick) {
    if (!item) continue;
    actions.push({
      id,
      button,
      label: item.label,
      help: item.help,
      script: item.script,
      args: staticArguments(item),
      caution: item.caution === true,
    });
  }
  return actions;
}

/** "3 min ago" for a measurement's timestamp; "" when it cannot be read. */
export function measuredAgo(iso: string, now: number): string {
  const at = Date.parse(iso);
  if (!Number.isFinite(at)) return "";
  const seconds = Math.max(0, Math.round((now - at) / 1000));
  if (seconds < 10) return "just now";
  if (seconds < 60) return `${seconds} s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  return `${Math.round(minutes / 60)} h ago`;
}
