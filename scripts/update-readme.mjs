#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const args = new Set(process.argv.slice(2));
const heartbeatOnly = args.has("--heartbeat-only");
const opsSnapshotPath = argumentValue("--ops-snapshot");
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

function zonedDateParts(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);

  return Object.fromEntries(parts.map((part) => [part.type, part.value]));
}

function isoDate(date = new Date()) {
  const { year, month, day } = zonedDateParts(date);
  return `${year}-${month}-${day}`;
}

function displayDate(date = new Date()) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(date);
}

function daysAgoIso(days) {
  const now = new Date();
  now.setUTCDate(now.getUTCDate() - days);
  return isoDate(now);
}

function extractJson(raw) {
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) {
    throw new Error("tokscale did not return JSON output");
  }

  return JSON.parse(raw.slice(start, end + 1));
}

function runTokscale(extraArgs) {
  const output = execFileSync("tokscale", ["--json", "--no-spinner", ...extraArgs], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 30 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });

  return extractJson(output);
}

function totalTokens(report) {
  return (
    report.totalInput +
    report.totalOutput +
    report.totalCacheRead +
    report.totalCacheWrite
  );
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

function usageRow(label, report) {
  return `| ${label} | ${formatInteger(totalTokens(report))} | ${formatCurrency(report.totalCost)} | ${formatInteger(report.totalMessages)} |`;
}

function buildUsageSection() {
  const today = isoDate();
  const reports = [
    ["Today", runTokscale(["--today"])],
    ["Last 7 days", runTokscale(["--week"])],
    ["Last 30 days", runTokscale(["--since", daysAgoIso(29), "--until", today])],
    ["All time", runTokscale([])],
  ];

  return [
    "## AI Usage",
    "",
    "| Window | Tokens | Cost | Messages |",
    "| --- | ---: | ---: | ---: |",
    ...reports.map(([label, report]) => usageRow(label, report)),
    "",
    "<p align=\"center\">",
    `  <sub>Usage snapshot generated ${displayDate()}. Aggregated from local cc-switch data; live card served by Tokscale.</sub>`,
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

function updateUsage(readme) {
  const section = buildUsageSection();
  const pattern = /## AI Usage\n\n\| Window \| Tokens \| Cost \| Messages \|\n\| --- \| ---: \| ---: \| ---: \|\n(?:\| [^\n]+\n)+\n<p align="center">\n  <sub>[^\n]*<\/sub>\n<\/p>/;

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
  readme = updateUsage(readme);
}

if (opsSnapshotPath) {
  readme = updateOps(readme, loadOpsSnapshot(opsSnapshotPath));
}

writeFileSync(readmePath, readme);
