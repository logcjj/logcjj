#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const args = new Set(process.argv.slice(2));
const heartbeatOnly = args.has("--heartbeat-only");
const opsSnapshotPath = argumentValue("--ops-snapshot");
const usageSnapshotPath = argumentValue("--usage-snapshot");
const timeZone = process.env.PROFILE_TIME_ZONE || "Asia/Shanghai";
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const readmePath = join(repoRoot, "README.md");

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  if (index === -1) {
    return null;
  }

  const value = process.argv[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`${name} requires a value`);
  }

  return value;
}

function displayDate(date = new Date()) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(date);
}

function formatInteger(value) {
  return Math.round(value).toLocaleString("en-US");
}

function formatCurrency(value) {
  return `$${value.toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

function formatDecimal(value) {
  return value.toLocaleString("en-US", {
    minimumFractionDigits: 1,
    maximumFractionDigits: 1,
  });
}

function formatPercent(value) {
  return `${(value * 100).toFixed(2)}%`;
}

function markdownCell(value) {
  return String(value).replaceAll("\\", "\\\\").replaceAll("|", "\\|").replaceAll("\n", " ");
}

function usageRow(label, report) {
  return `| ${label} | ${formatInteger(report.tokens)} | ${formatCurrency(report.cost)} | ${formatInteger(report.messages)} |`;
}

function requiredUsageNumber(value, field) {
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`Invalid cc-switch usage field: ${field}`);
  }

  return value;
}

function loadUsageSnapshot(path) {
  const snapshot = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(snapshot?.windows) || !Array.isArray(snapshot?.models)) {
    throw new Error("cc-switch usage snapshot must contain windows and models arrays");
  }

  const windows = snapshot.windows.map((window, index) => ({
    label: String(window.label || ""),
    tokens: requiredUsageNumber(window.tokens, `windows[${index}].tokens`),
    cost: requiredUsageNumber(window.cost, `windows[${index}].cost`),
    messages: requiredUsageNumber(window.messages, `windows[${index}].messages`),
  }));

  const expectedWindows = ["Today", "Last 7 days", "Last 30 days", "All time"];
  if (windows.length !== expectedWindows.length || windows.some(({ label }, index) => label !== expectedWindows[index])) {
    throw new Error("cc-switch usage snapshot contains invalid windows");
  }

  const models = snapshot.models.map((model, index) => ({
    app: String(model.app || ""),
    model: String(model.model || ""),
    tokens: requiredUsageNumber(model.tokens, `models[${index}].tokens`),
    cost: requiredUsageNumber(model.cost, `models[${index}].cost`),
    messages: requiredUsageNumber(model.messages, `models[${index}].messages`),
  }));

  if (models.length === 0 || windows.some(({ label }) => !label) || models.some(({ app, model }) => !app || !model)) {
    throw new Error("cc-switch usage snapshot contains an empty label");
  }

  return { windows, models };
}

function buildUsageSection(snapshot) {
  const modelRows = snapshot.models.slice(0, 8).map(({ app, model, tokens, cost, messages }) =>
    `| ${markdownCell(app)} | ${markdownCell(model)} | ${formatInteger(tokens)} | ${formatCurrency(cost)} | ${formatInteger(messages)} |`,
  );

  return [
    "## AI Usage",
    "",
    "| Window | Tokens | Cost | Requests |",
    "| --- | ---: | ---: | ---: |",
    ...snapshot.windows.map((report) => usageRow(report.label, report)),
    "",
    "### Top Models",
    "",
    "| App | Model | Tokens | Cost | Requests |",
    "| --- | --- | ---: | ---: | ---: |",
    ...modelRows,
    "",
    "<p align=\"center\">",
    `  <sub>Usage snapshot generated ${displayDate()}. Model and cost data come directly from cc-switch; the live card is served by Tokscale.</sub>`,
    "</p>",
  ].join("\n");
}

function requiredNumber(value, field) {
  if (!Number.isFinite(value)) {
    throw new Error(`Invalid Sub2API snapshot field: ${field}`);
  }

  return value;
}

function loadOpsSnapshot(path) {
  const payload = JSON.parse(readFileSync(path, "utf8"));
  if (payload.code !== undefined && payload.code !== 0) {
    throw new Error(`Sub2API snapshot request failed: ${payload.message || payload.code}`);
  }

  const snapshot = payload.data || payload;
  if (!snapshot?.overview) {
    throw new Error("Sub2API snapshot does not contain an overview");
  }

  return snapshot;
}

function buildOpsSection(snapshot) {
  const overview = snapshot.overview;
  const start = new Date(overview.start_time);
  const end = new Date(overview.end_time);
  const windowHours = Math.round((end - start) / (60 * 60 * 1000));

  if (!Number.isFinite(windowHours) || windowHours <= 0) {
    throw new Error("Invalid Sub2API snapshot time window");
  }

  const requests = requiredNumber(overview.request_count_total, "request_count_total");
  const tokens = requiredNumber(overview.token_consumed, "token_consumed");
  const sla = requiredNumber(overview.sla, "sla");
  const averageTps = requiredNumber(overview.tps?.avg, "tps.avg");
  const p50Latency = requiredNumber(overview.duration?.p50_ms, "duration.p50_ms");
  const generatedAt = snapshot.generated_at ? new Date(snapshot.generated_at) : end;

  if (Number.isNaN(generatedAt.getTime())) {
    throw new Error("Invalid Sub2API snapshot generation time");
  }

  return [
    "<!-- sub2api-ops:start -->",
    "## API Operations",
    "",
    "| Window | Requests | Routed Tokens | SLA | Avg TPS | P50 Latency |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
    `| Last ${windowHours} hours | ${formatInteger(requests)} | ${formatInteger(tokens)} | ${formatPercent(sla)} | ${formatDecimal(averageTps)} | ${formatInteger(p50Latency)} ms |`,
    "",
    "<p align=\"center\">",
    `  <sub>Sanitized Sub2API operations snapshot generated ${displayDate(generatedAt)}. No user, key, account, host, or request identifiers are published.</sub>`,
    "</p>",
    "<!-- sub2api-ops:end -->",
  ].join("\n");
}

function updateHeartbeat(readme) {
  const stamp = `<!-- profile-auto-refresh: ${new Date().toISOString()} -->`;
  if (readme.includes("<!-- profile-auto-refresh:")) {
    return readme.replace(/<!-- profile-auto-refresh: .*? -->/, stamp);
  }

  return `${stamp}\n${readme}`;
}

function updateTokscaleCacheKey(readme) {
  const cacheKey = new Date().toISOString();
  const pattern = /https:\/\/tokscale\.ai\/api\/embed\/logcjj\/svg\?[^"]+/;

  if (!pattern.test(readme)) {
    throw new Error("Could not find the Tokscale embed URL in README.md");
  }

  return readme.replace(pattern, (match) => {
    const url = new URL(match);
    url.searchParams.set("cache", cacheKey);
    return url.toString();
  });
}

function updateUsage(readme, snapshot) {
  const section = buildUsageSection(snapshot);
  const pattern = /## AI Usage[\s\S]*?(?=\n\n<!-- sub2api-ops:start -->)/;

  if (!pattern.test(readme)) {
    throw new Error("Could not find the AI Usage section in README.md");
  }

  return readme.replace(pattern, section);
}

function updateOps(readme, snapshot) {
  const section = buildOpsSection(snapshot);
  const pattern = /<!-- sub2api-ops:start -->[\s\S]*?<!-- sub2api-ops:end -->/;

  if (!pattern.test(readme)) {
    throw new Error("Could not find the Sub2API operations section in README.md");
  }

  return readme.replace(pattern, section);
}

let readme = readFileSync(readmePath, "utf8");
readme = updateHeartbeat(readme);
readme = updateTokscaleCacheKey(readme);

if (!heartbeatOnly) {
  if (!usageSnapshotPath) {
    throw new Error("--usage-snapshot is required unless --heartbeat-only is used");
  }
  readme = updateUsage(readme, loadUsageSnapshot(usageSnapshotPath));
}

if (opsSnapshotPath) {
  readme = updateOps(readme, loadOpsSnapshot(opsSnapshotPath));
}

writeFileSync(readmePath, readme);
