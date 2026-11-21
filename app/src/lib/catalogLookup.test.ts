import { describe, expect, it } from "vitest";
import { toolStillShips } from "./catalogLookup";
import type { Catalog, CatalogItem } from "./types";

const item = (script: string): CatalogItem => ({
  key: "1",
  label: script,
  script,
  help: "",
  caution: false,
  requiresProject: false,
  projectArgName: null,
  requiresFile: null,
  prompts: null,
  staticArgs: null,
});

const catalog = (loadErrors: string[] = []): Catalog => ({
  modules: [
    { group: "Network", folder: "wifi", name: "WiFi", description: "", items: [item("WiFi-Optimize.ps1"), item("WiFi-Scan.ps1")] },
    { group: "Dev", folder: "ports", name: "Ports", description: "", items: [item("Scan-Ports.ps1")] },
  ],
  loadErrors,
});

describe("toolStillShips", () => {
  it("is true for a tool the catalog lists", () => {
    expect(toolStillShips(catalog(), "wifi", "WiFi-Scan.ps1")).toBe(true);
  });

  it("is false for a tool that was removed", () => {
    expect(toolStillShips(catalog(), "maintenance", "Clear-TempFiles.ps1")).toBe(false);
  });

  it("is false for a script that moved out of the folder the run recorded", () => {
    expect(toolStillShips(catalog(), "ports", "WiFi-Scan.ps1")).toBe(false);
  });

  it("ignores case, like the file system the scripts live on", () => {
    expect(toolStillShips(catalog(), "WiFi", "wifi-scan.PS1")).toBe(true);
  });

  it("does not call a tool removed while the catalog has not loaded", () => {
    expect(toolStillShips(undefined, "maintenance", "Clear-TempFiles.ps1")).toBe(true);
  });

  it("does not call a tool removed when a category failed to load", () => {
    // Its manifest is broken, so it is missing from the catalog - but the
    // script may well be on disk.
    expect(toolStillShips(catalog(["docker: manifest did not parse"]), "docker", "Docker-Cleanup.ps1")).toBe(true);
  });

  it("copes with a single module or item arriving as a bare object", () => {
    const bare = {
      modules: { group: "Dev", folder: "ports", name: "Ports", description: "", items: item("Scan-Ports.ps1") },
      loadErrors: [],
    } as unknown as Catalog;
    expect(toolStillShips(bare, "ports", "Scan-Ports.ps1")).toBe(true);
    expect(toolStillShips(bare, "ports", "Kill-Port.ps1")).toBe(false);
  });
});
