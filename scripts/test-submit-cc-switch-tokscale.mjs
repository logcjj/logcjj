#!/usr/bin/env node

import assert from "node:assert/strict";
import { buildProviderPayload } from "./submit-cc-switch-tokscale.mjs";

function fixture(provider = "codex", client = "synthetic") {
  return {
    meta: { generatedAt: "2026-08-05T00:00:00Z", version: "4.5.1", dateRange: { start: "2026-08-05", end: "2026-08-05" } },
    summary: { totalTokens: 10, totalCost: 1.25, totalDays: 1, activeDays: 1, averagePerDay: 1.25, maxCostInSingleDay: 1.25, clients: ["synthetic"], models: ["gpt-5.5"] },
    years: [{ year: "2026", totalTokens: 10, totalCost: 1.25, range: { start: "2026-08-05", end: "2026-08-05" } }],
    contributions: [{
      date: "2026-08-05",
      totals: { tokens: 10, cost: 1.25, messages: 1 },
      intensity: 1,
      tokenBreakdown: { input: 6, output: 1, cacheRead: 3, cacheWrite: 0, reasoning: 0 },
      clients: [{ client, modelId: "gpt-5.5", providerId: provider, tokens: { input: 6, output: 1, cacheRead: 3, cacheWrite: 0, reasoning: 0 }, cost: 1.25, messages: 1 }],
    }],
  };
}

const graph = fixture();
const payload = buildProviderPayload(graph, { id: "dev_test", name: "Test" });
assert.deepEqual(payload.summary.clients, ["codex"]);
assert.equal(payload.contributions[0].clients[0].client, "codex");
assert.equal(payload.contributions[0].clients[0].modelId, "gpt-5.5");
assert.deepEqual(payload.device, { id: "dev_test", name: "Test" });
assert.equal(graph.contributions[0].clients[0].client, "synthetic");
assert.equal(buildProviderPayload(fixture("claude", "claude"), { id: "dev_test" }).contributions[0].clients[0].client, "claude");
assert.throws(() => buildProviderPayload(fixture("unsupported"), { id: "dev_test" }), /Unsupported cc-switch app type/);

const inconsistent = fixture();
inconsistent.summary.totalTokens = 11;
assert.throws(() => buildProviderPayload(inconsistent, { id: "dev_test" }), /summary tokens mismatch/);

console.log("cc-switch Tokscale submit tests passed");
