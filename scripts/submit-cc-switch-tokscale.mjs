#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const supportedProviders = new Set(["codex", "claude", "gemini"]);

function requiredObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function requiredNonNegative(value, label) {
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${label} must be a non-negative number`);
  }
  return value;
}

function tokenTotal(tokens, label) {
  requiredObject(tokens, label);
  return ["input", "output", "cacheRead", "cacheWrite", "reasoning"]
    .map((field) => requiredNonNegative(tokens[field], `${label}.${field}`))
    .reduce((sum, value) => sum + value, 0);
}

function assertClose(actual, expected, label, absoluteTolerance) {
  const tolerance = Math.max(Math.abs(expected) * 0.000001, absoluteTolerance);
  if (Math.abs(actual - expected) > tolerance) {
    throw new Error(`${label} mismatch: expected ${expected}, got ${actual}`);
  }
}

function validateTotals(graph) {
  requiredObject(graph, "graph");
  requiredObject(graph.summary, "graph.summary");
  if (!Array.isArray(graph.contributions) || graph.contributions.length === 0) {
    throw new Error("graph.contributions must be a non-empty array");
  }

  let totalTokens = 0;
  let totalCost = 0;
  for (const [dayIndex, day] of graph.contributions.entries()) {
    requiredObject(day, `graph.contributions[${dayIndex}]`);
    requiredObject(day.totals, `graph.contributions[${dayIndex}].totals`);
    if (!Array.isArray(day.clients) || day.clients.length === 0) {
      throw new Error(`graph.contributions[${dayIndex}].clients must be non-empty`);
    }

    const dayTokens = requiredNonNegative(day.totals.tokens, `day ${day.date} tokens`);
    const dayCost = requiredNonNegative(day.totals.cost, `day ${day.date} cost`);
    const breakdownTokens = tokenTotal(day.tokenBreakdown, `day ${day.date} tokenBreakdown`);
    const clientTokens = day.clients.reduce(
      (sum, client, clientIndex) => sum + tokenTotal(client.tokens, `day ${day.date} client ${clientIndex} tokens`),
      0,
    );
    const clientCost = day.clients.reduce(
      (sum, client, clientIndex) => sum + requiredNonNegative(client.cost, `day ${day.date} client ${clientIndex} cost`),
      0,
    );

    assertClose(breakdownTokens, dayTokens, `day ${day.date} token breakdown`, 0);
    assertClose(clientTokens, dayTokens, `day ${day.date} client tokens`, 0);
    assertClose(clientCost, dayCost, `day ${day.date} client cost`, 0.000001);
    totalTokens += dayTokens;
    totalCost += dayCost;
  }

  assertClose(totalTokens, requiredNonNegative(graph.summary.totalTokens, "summary.totalTokens"), "summary tokens", 0);
  assertClose(totalCost, requiredNonNegative(graph.summary.totalCost, "summary.totalCost"), "summary cost", 0.000001);
}

export function buildProviderPayload(graph, device) {
  validateTotals(graph);
  requiredObject(device, "device");
  if (typeof device.id !== "string" || !device.id.trim()) {
    throw new Error("device.id must be a non-empty string");
  }

  const payload = JSON.parse(JSON.stringify(graph));
  const clients = new Set();

  for (const day of payload.contributions) {
    for (const contribution of day.clients) {
      const provider = String(contribution.providerId || "").trim().toLowerCase();
      if (!supportedProviders.has(provider)) {
        throw new Error(`Unsupported cc-switch app type: ${provider || "<empty>"}`);
      }
      if (contribution.client !== "synthetic" && contribution.client !== provider) {
        throw new Error(`Unexpected bridge client: ${contribution.client}`);
      }

      contribution.client = provider;
      contribution.providerId = provider;
      clients.add(provider);
    }
  }

  payload.summary.clients = [...clients].sort();
  payload.device = {
    id: device.id.trim(),
    ...(typeof device.name === "string" && device.name.trim() ? { name: device.name.trim() } : {}),
  };

  return payload;
}

async function readJson(path, label) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    throw new Error(`Could not read ${label} at ${path}: ${error.message}`);
  }
}

async function loadAuth() {
  const configDir = process.env.TOKSCALE_CONFIG_DIR || join(homedir(), ".config", "tokscale");
  const credentials = await readJson(join(configDir, "credentials.json"), "Tokscale credentials");
  const storedDevice = await readJson(join(configDir, "device.json"), "Tokscale device");
  const token = String(process.env.TOKSCALE_API_TOKEN || credentials.token || "").trim();
  const device = {
    id: String(process.env.TOKSCALE_DEVICE_ID || storedDevice.id || "").trim(),
    name: process.env.TOKSCALE_DEVICE_NAME || storedDevice.name,
  };

  if (!token) throw new Error("Tokscale API token is missing");
  return { token, device };
}

async function apiRequest(url, token, options) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const response = await fetch(url, {
        ...options,
        headers: {
          Authorization: `Bearer ${token}`,
          ...(options.body ? { "Content-Type": "application/json" } : {}),
        },
        signal: AbortSignal.timeout(60_000),
      });
      const text = await response.text();
      const body = text ? JSON.parse(text) : {};
      if (!response.ok) {
        const details = Array.isArray(body.details) ? `: ${body.details.join("; ")}` : "";
        throw new Error(`${body.error || `HTTP ${response.status}`}${details}`);
      }
      return body;
    } catch (error) {
      lastError = error;
      if (attempt < 3) await new Promise((resolveDelay) => setTimeout(resolveDelay, 2_000));
    }
  }
  throw lastError;
}

async function main() {
  const args = process.argv.slice(2);
  const graphPath = args.find((arg) => !arg.startsWith("--"));
  const dryRun = args.includes("--dry-run");
  const replaceAll = args.includes("--replace-all");
  if (!graphPath || (dryRun && replaceAll)) {
    throw new Error("Usage: submit-cc-switch-tokscale.mjs GRAPH_PATH [--dry-run | --replace-all]");
  }

  const graph = await readJson(resolve(graphPath), "Tokscale graph");
  const { token, device } = await loadAuth();
  const payload = buildProviderPayload(graph, device);
  const clientNames = payload.summary.clients.join(", ");
  console.log(`cc-switch Tokscale payload ready: ${payload.summary.totalTokens} tokens; clients: ${clientNames}`);

  if (dryRun) return;

  const apiUrl = (process.env.TOKSCALE_API_URL || "https://tokscale.ai").replace(/\/$/, "");
  if (replaceAll) {
    const deleted = await apiRequest(`${apiUrl}/api/settings/submitted-data`, token, { method: "DELETE" });
    console.log(`Deleted ${deleted.deletedSubmissions ?? 0} existing Tokscale submission(s).`);
  }

  const result = await apiRequest(`${apiUrl}/api/submit`, token, {
    method: "POST",
    body: JSON.stringify(payload),
  });
  console.log(`Tokscale provider snapshot submitted for ${result.username || "current user"}.`);
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
