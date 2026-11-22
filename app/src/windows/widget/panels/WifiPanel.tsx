import { useEffect, useRef, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import clsx from "clsx";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useConfirmDestructive } from "../../../hooks/useConfirmDestructive";
import { rpcCall } from "../../../lib/ipc";
import { asArray } from "../../../lib/arrays";
import { playSound } from "../../../lib/sounds";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { Button } from "../../../components/primitives/Button";
import { ToolConsole } from "../../../components/ToolConsole";
import { WifiIcon } from "./icons";
import type { Catalog, WifiMeasureReport, WifiScanReport, WifiStatus } from "../../../lib/types";
import { useOnScreen } from "./git/paneVisibility";
import { startWidgetToolRun, stopWatchingWidgetRun, useWidgetToolRun } from "./widgetToolRun";
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
  type WifiAction,
} from "./wifiModel";
import "./WifiPanel.css";

/**
 * How often the status line is read while the tray is open. One read is a
 * few hundred milliseconds of the sidecar's own 'network' lane (no pings, no
 * lookups), and the things it shows - which network, how strong - do not
 * move faster than this.
 */
const STATUS_POLL_MS = 10000;

/**
 * The WiFi tray: look, measure, fix, look again - in one place.
 *
 * Three read-only sidecar methods feed it (core/RpcMethods.ps1, "wifi.*"):
 *
 *   wifi.status   polled while the tray is open AND on screen; nothing asks
 *                 while it is shut. The sidecar does not even start the lane
 *                 these ride until the first one arrives.
 *   wifi.measure  on the Measure button only: 5-10 seconds of real pings and
 *                 DNS lookups, then the findings in plain words.
 *   wifi.scan     on the Nearby networks button only.
 *
 * Nothing here changes a network setting. The fix buttons run the existing
 * WiFi tools (tools/wifi) through the widget's shared tool-run channel,
 * each behind the same caution confirmation the Control Center shows; which
 * script and which arguments come from the catalog, not from this file (see
 * wifiActionsFromCatalog).
 */
export function WifiPanel({ active = true }: { active?: boolean } = {}) {
  const rootRef = useRef<HTMLDivElement>(null);
  // Docked, this is a tray pane, and a shut pane stays mounted: `useOnScreen`
  // is what says the pane is actually open. Floating, there is no pane and
  // that reads always-on, so the widget wraps this panel in an Expander and
  // passes `active` - the same two-part gate the Node & Ports panel has.
  const paneOpen = useOnScreen(rootRef);
  const onScreen = active && paneOpen;
  const confirmDestructive = useConfirmDestructive();

  const status = usePolledRpc<WifiStatus>("wifi.status", undefined, STATUS_POLL_MS, onScreen);
  const connection = describeConnection(status.data);
  const signal = signalQuality(status.data?.SignalPercent);

  const [measure, setMeasure] = useState<WifiMeasureReport | null>(null);
  const [measuring, setMeasuring] = useState(false);
  const [measureError, setMeasureError] = useState<string | null>(null);
  const [scan, setScan] = useState<WifiScanReport | null>(null);
  const [scanning, setScanning] = useState(false);
  const [scanError, setScanError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  // A slow answer must not land in a tray that has since been closed.
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  // "3 min ago" only needs to move while there is a measurement on screen.
  useEffect(() => {
    if (!measure || !onScreen) return;
    const timer = window.setInterval(() => setNow(Date.now()), 30000);
    return () => window.clearInterval(timer);
  }, [measure, onScreen]);

  // The fix buttons come from the catalog: one cached read, shared with the
  // palette and the Control Center, asked for only once the tray is seen.
  const { data: catalog } = useQuery({
    queryKey: ["catalog.get"],
    queryFn: () => rpcCall<Catalog>("catalog.get"),
    staleTime: Infinity,
    enabled: onScreen,
  });
  const actions = wifiActionsFromCatalog(catalog);

  const run = useWidgetToolRun();
  const mine = run.surface === "wifi";
  const blockedBy = run.label && !mine ? run.label : null;
  const anythingRunning = !!run.runId;

  // A fix that has just finished changed something: read the status again
  // now rather than at the next tick.
  const { refetch: refetchStatus } = status;
  const lastRunId = useRef<string | null>(null);
  useEffect(() => {
    if (mine && run.runId) lastRunId.current = run.runId;
    if (mine && !run.runId && lastRunId.current) {
      lastRunId.current = null;
      void refetchStatus();
    }
  }, [mine, run.runId, refetchStatus]);

  async function runMeasure() {
    if (measuring) return;
    playSound("click");
    setMeasuring(true);
    setMeasureError(null);
    try {
      const report = await rpcCall<WifiMeasureReport>("wifi.measure");
      if (!mounted.current) return;
      setMeasure(report);
      setNow(Date.now());
    } catch (err) {
      if (mounted.current) setMeasureError(err instanceof Error ? err.message : String(err));
    } finally {
      if (mounted.current) setMeasuring(false);
    }
  }

  async function runScan() {
    if (scanning) return;
    playSound("click");
    setScanning(true);
    setScanError(null);
    try {
      const report = await rpcCall<WifiScanReport>("wifi.scan", { rescan: true });
      if (mounted.current) setScan(report);
    } catch (err) {
      if (mounted.current) setScanError(err instanceof Error ? err.message : String(err));
    } finally {
      if (mounted.current) setScanning(false);
    }
  }

  function runAction(action: WifiAction) {
    if (anythingRunning) return;
    const start = () => {
      void startWidgetToolRun({
        surface: "wifi",
        folder: "wifi",
        script: action.script,
        label: action.label,
        args: action.args,
        caution: action.caution,
        // Only ever true on the way out of the confirmation below - it is
        // what lets the sidecar skip the tool's own console prompt, which
        // nobody could answer here. See widgetToolRun's WidgetRunSpec.
        confirmed: action.caution,
      });
    };
    if (!action.caution) {
      start();
      return;
    }
    confirmDestructive(
      {
        title: `${action.label}?`,
        description: (
          <>
            {action.help}
            <br />
            Runs <code>{`wifi/${action.script}${action.args.length > 0 ? ` ${action.args.join(" ")}` : ""}`}</code>. Its
            output appears in this tray.
          </>
        ),
        confirmLabel: action.button,
        danger: true,
      },
      // Fired, not returned: the dialog's job ends at "yes". Returning the
      // run's promise would keep the dialog up for the whole run.
      start,
    );
  }

  const data = status.data;

  return (
    <GlassPanel>
      <div ref={rootRef} className="panel-header">
        <span className="panel-header__icon">
          <WifiIcon />
        </span>
        <h2 className="panel-header__title">WiFi</h2>
        {status.pending && <span className="panel-header__hint">checking…</span>}
        {status.stale && <span className="panel-header__hint wifi-panel__stale">last known — sidecar not answering</span>}
      </div>

      {status.failed ? (
        <div className="panel-empty panel-empty--danger" role="alert">
          Couldn&apos;t read the WiFi connection{status.errorMessage ? ` - ${status.errorMessage}` : "."}
        </div>
      ) : (
        <div className="wifi-panel">
          {/* ---------- what this PC is connected to ---------- */}
          <section className="wifi-panel__status" aria-label="Connection">
            <div className="wifi-panel__headline">
              <span className={clsx("wifi-panel__ssid", !connection.connected && "wifi-panel__ssid--off")}>{connection.title}</span>
              {connection.connected && data?.SignalPercent !== null && data?.SignalPercent !== undefined && (
                <Badge tone={signal.tone}>
                  {signal.label} · {data.SignalPercent}%
                </Badge>
              )}
            </div>
            {connection.detail && <p className="wifi-panel__note">{connection.detail}</p>}
            {connection.connected && data && (
              <dl className="wifi-panel__facts">
                <Fact name="Band" value={formatBand(data)} />
                <Fact name="Link rate" value={data.RxMbps === data.TxMbps ? formatMbps(data.RxMbps) : `${formatMbps(data.RxMbps)} down / ${formatMbps(data.TxMbps)} up`} />
                <Fact name="Address" value={data.IPv4 || "n/a"} />
                <Fact name="Router" value={data.Gateway || "n/a"} />
                <Fact
                  name="DNS"
                  value={asArray(data.DnsServers).length > 0 ? asArray(data.DnsServers).join(", ") : "n/a"}
                  extra={data.DnsIsStatic ? <Badge tone="warning">set by hand</Badge> : null}
                />
              </dl>
            )}
          </section>

          {/* ---------- read-only checks ---------- */}
          <div className="wifi-panel__buttons">
            <Button size="sm" variant="primary" loading={measuring} disabled={!connection.connected} onClick={() => void runMeasure()}>
              Measure
            </Button>
            <Button size="sm" loading={scanning} disabled={!data?.AdapterPresent} onClick={() => void runScan()}>
              Nearby networks
            </Button>
          </div>
          {measuring && <p className="wifi-panel__note">Measuring the router, the internet and DNS - about ten seconds. Nothing is changed.</p>}
          {scanning && <p className="wifi-panel__note">Asking the adapter for a fresh scan - a few seconds. The connection is not dropped.</p>}

          {measureError && (
            <div className="panel-empty panel-empty--danger" role="alert">
              The measurement did not finish - {measureError}
            </div>
          )}
          {measure && <MeasureResult report={measure} now={now} />}

          {scanError && (
            <div className="panel-empty panel-empty--danger" role="alert">
              The scan did not finish - {scanError}
            </div>
          )}
          {scan && <ScanResult report={scan} />}

          {/* ---------- fixes: the existing tools, behind their confirmation ---------- */}
          {actions.length > 0 && (
            <section className="wifi-panel__fixes" aria-label="Fixes">
              <h3 className="wifi-panel__subhead">Fix</h3>
              <div className="wifi-panel__buttons">
                {actions.map((action) => (
                  <Button
                    key={action.id}
                    size="sm"
                    variant={action.id === "fix" ? "primary" : action.id === "deep" ? "danger" : "subtle"}
                    loading={mine && run.label === action.label && anythingRunning}
                    disabled={anythingRunning}
                    title={action.help}
                    onClick={() => runAction(action)}
                  >
                    {action.button}
                  </Button>
                ))}
              </div>
              <p className="wifi-panel__note">
                Each asks first, then measures, changes only what the measurement calls for, and measures again.
              </p>
              {blockedBy && <div className="wifi-panel__note">Waiting for {blockedBy} to finish.</div>}
              {mine && run.launchError && (
                <div className="panel-empty panel-empty--danger" role="alert">
                  {run.launchError}
                </div>
              )}
              {mine && (run.runId || run.lines.length > 0) && (
                <div className="wifi-panel__console">
                  <ToolConsole lines={run.lines} className="tool-console--compact" />
                  {run.degraded && (
                    <span className="wifi-panel__note">
                      The run request errored - still watching. To end the run, use Stop on its row in Run history.
                    </span>
                  )}
                  <div className="wifi-panel__console-footer">
                    {run.exitCode !== null && !run.runId && (
                      <span className={run.exitCode === 0 ? "wifi-panel__exit-ok" : "wifi-panel__exit-err"}>exit {run.exitCode}</span>
                    )}
                    {run.runId && (
                      <Button size="sm" variant="ghost" onClick={stopWatchingWidgetRun}>
                        Stop watching
                      </Button>
                    )}
                  </div>
                </div>
              )}
            </section>
          )}
        </div>
      )}
    </GlassPanel>
  );
}

function Fact({ name, value, extra }: { name: string; value: string; extra?: ReactNode }) {
  return (
    <div className="wifi-panel__fact">
      <dt>{name}</dt>
      <dd>
        <span className="wifi-panel__fact-value">{value}</span>
        {extra}
      </dd>
    </div>
  );
}

function MeasureResult({ report, now }: { report: WifiMeasureReport; now: number }) {
  const findings = sortFindings(asArray(report.Findings));
  const dns = report.DnsCurrent;
  return (
    <section className="wifi-panel__result" aria-label="Measurement">
      <div className="wifi-panel__result-head">
        <h3 className="wifi-panel__subhead">Measurement</h3>
        <Badge tone={report.Healthy ? "success" : "warning"}>{report.Healthy ? "healthy" : "needs attention"}</Badge>
        <span className="wifi-panel__ago">{measuredAgo(report.MeasuredAt, now)}</span>
      </div>
      <dl className="wifi-panel__facts">
        <Fact name="Router" value={formatPing(report.Router)} />
        <Fact name="Internet" value={formatPing(report.Internet)} />
        <Fact
          name="DNS"
          value={
            dns
              ? dns.MedianMs === null
                ? "not answering"
                : `${formatMs(dns.MedianMs)}${dns.FailurePct > 0 ? `, ${dns.FailurePct}% failed` : ""}`
              : "not measured"
          }
        />
        {report.Portal === "portal" && <Fact name="Sign-in page" value="in the way - sign in with a browser first" />}
      </dl>
      {findings.length === 0 ? (
        <p className="wifi-panel__note">Nothing wrong was found.</p>
      ) : (
        <ul className="wifi-panel__findings">
          {findings.map((finding) => (
            <li key={finding.Code} className="wifi-panel__finding">
              <Badge tone={findingTone(finding.Severity)}>{finding.Severity === "warn" ? "warning" : finding.Severity}</Badge>
              <span>{finding.Message}</span>
            </li>
          ))}
        </ul>
      )}
      <p className="wifi-panel__plan">{describeFixPlan(report)}</p>
    </section>
  );
}

function ScanResult({ report }: { report: WifiScanReport }) {
  const networks = asArray(report.Networks);
  const advice = asArray(report.Advice);
  if (report.Problem === "noAdapter") {
    return <div className="panel-empty">No WiFi adapter found.</div>;
  }
  if (report.Problem === "locationOff") {
    return (
      <div className="panel-empty">
        Windows is hiding WiFi details because Location is turned off. Turn it on in Settings &gt; Privacy &amp; security &gt;
        Location (&quot;Location services&quot; and &quot;Let desktop apps access your location&quot;).
      </div>
    );
  }
  return (
    <section className="wifi-panel__result" aria-label="Nearby networks">
      <div className="wifi-panel__result-head">
        <h3 className="wifi-panel__subhead">Nearby networks</h3>
        <Badge tone="neutral">{networks.length}</Badge>
      </div>
      {report.RescanState === "denied" && (
        <p className="wifi-panel__note">
          Windows refused a fresh scan, so this is its cached list - often just the network you are on. Location being off
          is the usual reason.
        </p>
      )}
      {report.RescanState === "unavailable" && (
        <p className="wifi-panel__note">A fresh scan could not be started, so this is Windows&apos; cached list.</p>
      )}
      {advice.length > 0 && (
        <ul className="wifi-panel__findings">
          {advice.map((line, index) => (
            <li key={index} className="wifi-panel__finding">
              <Badge tone={line.Level === "warn" ? "warning" : line.Level === "good" ? "success" : "neutral"}>
                {line.Level === "warn" ? "warning" : line.Level === "good" ? "good" : "tip"}
              </Badge>
              <span>{line.Text}</span>
            </li>
          ))}
        </ul>
      )}
      {networks.length === 0 ? (
        <p className="wifi-panel__note">No networks could be read.</p>
      ) : (
        <ul className="wifi-panel__networks">
          {networks.map((network, index) => {
            const quality = signalQuality(network.Signal);
            const bands = asArray(network.Bands).join(" + ");
            const channels = asArray(network.Channels).join(", ");
            return (
              <li key={`${network.Ssid}:${index}`} className={clsx("wifi-panel__network", network.IsCurrent && "wifi-panel__network--current")}>
                <div className="wifi-panel__network-name">
                  <span className={clsx(network.Hidden && "wifi-panel__hidden")}>{network.Hidden ? "(hidden network)" : network.Ssid}</span>
                  {network.IsCurrent && <Badge tone="accent">connected</Badge>}
                </div>
                <div className="wifi-panel__network-meta">
                  {network.Auth || "unknown security"}
                  {bands ? ` · ${bands}` : ""}
                  {channels ? ` · ch ${channels}` : ""}
                  {network.AccessPoints > 1 ? ` · ${network.AccessPoints} access points` : ""}
                </div>
                <Badge tone={quality.tone}>{network.Signal}%</Badge>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
