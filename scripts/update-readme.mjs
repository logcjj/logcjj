#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const args = new Set(process.argv.slice(2));
const heartbeatOnly = args.has("--heartbeat-only");
const timeZone = process.env.PROFILE_TIME_ZONE || "Asia/Shanghai";
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const readmePath = join(repoRoot, "README.md");

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

function updateHeartbeat(readme) {
  const stamp = `<!-- profile-auto-refresh: ${new Date().toISOString()} -->`;
  if (readme.includes("<!-- profile-auto-refresh:")) {
    return readme.replace(/<!-- profile-auto-refresh: .*? -->/, stamp);
  }

  return `${stamp}\n${readme}`;
}

function updateUsage(readme) {
  const section = buildUsageSection();
  const pattern = /## AI Usage\n\n\| Window \| Tokens \| Cost \| Messages \|\n\| --- \| ---: \| ---: \| ---: \|\n(?:\| .+\n)+\n<p align="center">\n  <sub>.*?<\/sub>\n<\/p>/s;

  if (!pattern.test(readme)) {
    throw new Error("Could not find the AI Usage section in README.md");
  }

  return readme.replace(pattern, section);
}

let readme = readFileSync(readmePath, "utf8");
readme = updateHeartbeat(readme);

if (!heartbeatOnly) {
  readme = updateUsage(readme);
}

writeFileSync(readmePath, readme);
