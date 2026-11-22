import { describe, expect, it } from "vitest";
import type { Catalog, CatalogItem, WifiMeasureReport, WifiStatus } from "../../../lib/types";
import {
  describeConnection,
  describeFixPlan,
  findingTone,
  formatBand,
  formatMbps,
  formatMs,
  formatPing,
  measuredAgo,
  signalQuality,
  sortFindings,
  wifiActionsFromCatalog,
} from "./wifiModel";

const status = (over: Partial<WifiStatus> = {}): WifiStatus => ({
  AdapterPresent: true,
  Connected: true,
  DetailsHidden: false,
  InterfaceAlias: "Wi-Fi",
  Ssid: "HomeNet",
  Bssid: "aa:bb:cc:dd:ee:01",
  SignalPercent: 86,
  Band: "5 GHz",
  Channel: 161,
  RadioType: "802.11ax",
  RxMbps: 287,
  TxMbps: 287,
  IPv4: "192.168.0.21",
  Gateway: "192.168.0.1",
  DnsServers: ["192.168.0.1"],
  DnsIsStatic: false,
  ...over,
});

describe("signalQuality", () => {
  it("uses the diagnosis's own threshold for weak (below 40), so badge and finding agree", () => {
    expect(signalQuality(39).label).toBe("Weak");
    expect(signalQuality(39).tone).toBe("danger");
    expect(signalQuality(40).label).toBe("Fair");
  });

  it("grades the rest", () => {
    expect(signalQuality(54).label).toBe("Fair");
    expect(signalQuality(55).label).toBe("Good");
    expect(signalQuality(74).label).toBe("Good");
    expect(signalQuality(75).label).toBe("Excellent");
    expect(signalQuality(100).tone).toBe("success");
  });

  it("says n/a for a signal Windows did not report, instead of grading nothing as weak", () => {
    expect(signalQuality(null)).toEqual({ label: "n/a", tone: "neutral" });
    expect(signalQuality(undefined).label).toBe("n/a");
    expect(signalQuality(Number.NaN).label).toBe("n/a");
  });
});

describe("formatting measurements", () => {
  it("never shows a number for something that was not measured", () => {
    expect(formatMs(null)).toBe("n/a");
    expect(formatMs(undefined)).toBe("n/a");
    expect(formatMbps(null)).toBe("n/a");
    expect(formatPing(null)).toBe("not measured");
  });

  it("keeps one decimal below 10 ms and rounds above", () => {
    expect(formatMs(2.44)).toBe("2.4 ms");
    expect(formatMs(18.06)).toBe("18 ms");
    expect(formatMs(0)).toBe("0.0 ms");
  });

  it("shows a ping with its jitter, and loss only when there is some", () => {
    expect(formatPing({ AverageMs: 18.1, JitterMs: 1.3, LossPct: 0 })).toBe("18 ms, jitter 1.3 ms");
    expect(formatPing({ AverageMs: 42, JitterMs: 12, LossPct: 20 })).toBe("42 ms, jitter 12 ms, 20% lost");
  });

  it("reports total loss as no reply, not as a latency", () => {
    expect(formatPing({ AverageMs: null, JitterMs: null, LossPct: 100 })).toBe("no reply to ping");
    expect(formatPing({ AverageMs: 0, JitterMs: 0, LossPct: 100 })).toBe("no reply to ping");
  });

  it("describes the band from whichever half Windows gave", () => {
    expect(formatBand({ Band: "5 GHz", Channel: 161 })).toBe("5 GHz, channel 161");
    expect(formatBand({ Band: "", Channel: 6 })).toBe("channel 6");
    expect(formatBand({ Band: "6 GHz", Channel: 0 })).toBe("6 GHz");
    expect(formatBand({ Band: "", Channel: 0 })).toBe("n/a");
  });
});

describe("describeConnection", () => {
  it("names the network when connected", () => {
    expect(describeConnection(status())).toEqual({ title: "HomeNet", detail: null, connected: true });
  });

  it("tells a PC without WiFi from one that is just not connected", () => {
    expect(describeConnection(status({ AdapterPresent: false, Connected: false })).title).toBe("No WiFi adapter");
    const idle = describeConnection(status({ Connected: false, Ssid: "" }));
    expect(idle.title).toBe("Not connected");
    expect(idle.connected).toBe(false);
    expect(idle.detail).toContain("Wi-Fi");
  });

  it("says why there is no name when Windows hides it, and still counts as connected", () => {
    const hidden = describeConnection(status({ DetailsHidden: true, Ssid: "", SignalPercent: null }));
    expect(hidden.title).toBe("Connected");
    expect(hidden.connected).toBe(true);
    expect(hidden.detail).toContain("Location");
  });

  it("claims nothing before the first answer", () => {
    expect(describeConnection(undefined)).toEqual({ title: "Checking…", detail: null, connected: false });
  });
});

describe("describeFixPlan", () => {
  const report = (over: Partial<WifiMeasureReport>): Pick<WifiMeasureReport, "Actions" | "BestDns" | "Healthy" | "Findings"> => ({
    Actions: [],
    BestDns: null,
    Healthy: true,
    Findings: [],
    ...over,
  });

  it("says there is nothing to fix on a healthy connection", () => {
    expect(describeFixPlan(report({}))).toBe("Nothing to fix.");
  });

  it("says so when the problem is not one a setting can fix", () => {
    // Weak signal, a busy channel, an outage past the router: findings, no actions.
    expect(describeFixPlan(report({ Healthy: false }))).toBe("Nothing here can be fixed by a setting on this PC.");
  });

  it("lists what WiFi Fix would do, in the order it would do it", () => {
    expect(describeFixPlan(report({ Healthy: false, Actions: ["FlushDns"] }))).toBe("WiFi Fix would clear the DNS cache.");
    expect(describeFixPlan(report({ Healthy: false, Actions: ["RenewLease", "RestartAdapter"] }))).toBe(
      "WiFi Fix would renew this PC's address and restart the WiFi adapter.",
    );
  });

  it("names the DNS server it would switch to", () => {
    expect(
      describeFixPlan(report({ Healthy: false, Actions: ["FlushDns", "SwitchDns"], BestDns: { Name: "Cloudflare", MedianMs: 11 } })),
    ).toBe("WiFi Fix would clear the DNS cache and switch DNS to Cloudflare.");
  });

  it("shows a fix it has no words for rather than leaving it out", () => {
    expect(describeFixPlan(report({ Healthy: false, Actions: ["FlushDns", "SomethingNew", "RenewLease"] }))).toBe(
      "WiFi Fix would clear the DNS cache, SomethingNew and renew this PC's address.",
    );
  });

  it("copes with a single action arriving as a bare value", () => {
    expect(describeFixPlan(report({ Healthy: false, Actions: "FlushDns" as unknown as string[] }))).toBe(
      "WiFi Fix would clear the DNS cache.",
    );
  });
});

describe("findings", () => {
  it("puts errors before warnings before notes, keeping the given order within each", () => {
    const sorted = sortFindings([
      { Severity: "info", Code: "a" },
      { Severity: "warn", Code: "b" },
      { Severity: "error", Code: "c" },
      { Severity: "warn", Code: "d" },
    ]);
    expect(sorted.map((f) => f.Code)).toEqual(["c", "b", "d", "a"]);
  });

  it("does not reorder the list it was given", () => {
    const given = [{ Severity: "info" }, { Severity: "error" }];
    sortFindings(given);
    expect(given[0].Severity).toBe("info");
  });

  it("colours by severity", () => {
    expect(findingTone("error")).toBe("danger");
    expect(findingTone("warn")).toBe("warning");
    expect(findingTone("info")).toBe("neutral");
  });
});

describe("wifiActionsFromCatalog", () => {
  const item = (over: Partial<CatalogItem>): CatalogItem => ({
    key: "1",
    label: "",
    script: "WiFi-Optimize.ps1",
    help: "",
    caution: false,
    requiresProject: false,
    projectArgName: null,
    requiresFile: null,
    prompts: null,
    staticArgs: null,
    ...over,
  });

  // The six entries of tools/wifi/_module.psd1, as catalog.get returns them.
  const realItems = [
    item({ key: "1", label: "WiFi Check (Measure and Diagnose)", staticArgs: { DiagnoseOnly: true } }),
    item({ key: "2", label: "WiFi Fix (Diagnose, Then Fix Only What Is Wrong)", help: "fix help", caution: true }),
    item({ key: "3", label: "WiFi Fix (Fast Mode)", script: "WiFi-FastMode.ps1", staticArgs: { Fast: true }, caution: true }),
    item({ key: "4", label: "WiFi Deep Reset (Network Stack)", staticArgs: { Deep: true }, caution: true }),
    item({ key: "5", label: "Undo DNS Change", staticArgs: { RestoreDns: true }, caution: true }),
    item({ key: "6", label: "WiFi Scanner", script: "WiFi-Scan.ps1" }),
  ];
  const catalog = (items: CatalogItem[]): Catalog => ({
    modules: [
      { group: "Dev", folder: "ports", name: "Ports", description: "", items: [item({ script: "WiFi-Optimize.ps1", label: "decoy in another folder" })] },
      { group: "Network", folder: "wifi", name: "WiFi Tools", description: "", items },
    ],
    loadErrors: [],
  });

  it("finds the four fix tools, with their scripts, arguments and caution flags", () => {
    const actions = wifiActionsFromCatalog(catalog(realItems));
    expect(actions.map((a) => a.id)).toEqual(["fix", "fast", "deep", "undoDns"]);
    expect(actions.map((a) => [a.script, a.args])).toEqual([
      ["WiFi-Optimize.ps1", []],
      ["WiFi-FastMode.ps1", ["-Fast"]],
      ["WiFi-Optimize.ps1", ["-Deep"]],
      ["WiFi-Optimize.ps1", ["-RestoreDns"]],
    ]);
    expect(actions.every((a) => a.caution)).toBe(true);
    expect(actions[0].label).toBe("WiFi Fix (Diagnose, Then Fix Only What Is Wrong)");
    expect(actions[0].help).toBe("fix help");
  });

  it("never offers the read-only check or the scanner as a fix", () => {
    const actions = wifiActionsFromCatalog(catalog(realItems));
    expect(actions.some((a) => a.args.includes("-DiagnoseOnly"))).toBe(false);
    expect(actions.some((a) => a.script === "WiFi-Scan.ps1")).toBe(false);
  });

  it("finds them whatever order or key the manifest gives them", () => {
    const shuffled = [...realItems].reverse().map((i, n) => ({ ...i, key: String(n + 10) }));
    expect(wifiActionsFromCatalog(catalog(shuffled)).map((a) => a.id)).toEqual(["fix", "fast", "deep", "undoDns"]);
  });

  it("offers no button for a tool the catalog does not have", () => {
    const withoutDeep = realItems.filter((i) => i.staticArgs?.Deep !== true);
    expect(wifiActionsFromCatalog(catalog(withoutDeep)).map((a) => a.id)).toEqual(["fix", "fast", "undoDns"]);
  });

  it("offers nothing before the catalog loads, or when it has no WiFi category", () => {
    expect(wifiActionsFromCatalog(undefined)).toEqual([]);
    expect(wifiActionsFromCatalog({ modules: [], loadErrors: [] })).toEqual([]);
  });

  it("does not mistake a dry-run entry for the real fix", () => {
    const withDryRun = [item({ label: "WiFi Fix (dry run)", staticArgs: { DryRun: true } }), ...realItems.slice(1)];
    const fix = wifiActionsFromCatalog(catalog(withDryRun)).find((a) => a.id === "fix");
    expect(fix?.label).toBe("WiFi Fix (Diagnose, Then Fix Only What Is Wrong)");
  });

  it("copes with a category holding one item as a bare object", () => {
    const bare = {
      modules: { group: "Network", folder: "wifi", name: "WiFi Tools", description: "", items: realItems[1] },
      loadErrors: [],
    } as unknown as Catalog;
    expect(wifiActionsFromCatalog(bare).map((a) => a.id)).toEqual(["fix"]);
  });
});

describe("measuredAgo", () => {
  const at = Date.parse("2026-11-21T18:30:00.000Z");
  it("reads as a person would say it", () => {
    expect(measuredAgo("2026-11-21T18:30:00.0000000Z", at + 3_000)).toBe("just now");
    expect(measuredAgo("2026-11-21T18:30:00.0000000Z", at + 45_000)).toBe("45 s ago");
    expect(measuredAgo("2026-11-21T18:30:00.0000000Z", at + 4 * 60_000)).toBe("4 min ago");
    expect(measuredAgo("2026-11-21T18:30:00.0000000Z", at + 3 * 3_600_000)).toBe("3 h ago");
  });

  it("is empty for a timestamp it cannot read, and never negative", () => {
    expect(measuredAgo("not a date", at)).toBe("");
    expect(measuredAgo("2026-11-21T18:30:00.0000000Z", at - 60_000)).toBe("just now");
  });
});
