/* Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. */
/* The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ */
const byId = id => document.getElementById(id);
let busy = false;
let ready = false;

async function refreshStatus() {
  if (busy) return;
  try {
    const response = await fetch("/api/status", {signal: AbortSignal.timeout(10000)});
    const data = await response.json();
    ready = response.ok && data.ready;
    byId("status").textContent = ready ? "● LiteLLM connected" : (data.error || "Missing aliases: " + data.missing.join(", "));
    byId("status").className = "status " + (ready ? "ready" : "failed");
    if (data.models) {
      byId("efficient").textContent = data.models.efficient;
      byId("capable").textContent = data.models.capable;
      byId("judge").textContent = "Judge: " + data.models.judge;
      byId("threshold").textContent = data.threshold.toFixed(2);
      byId("tokens").max = data.max_tokens;
      byId("tokens").value = Math.min(Number(byId("tokens").value), data.max_tokens);
    }
  } catch {
    ready = false;
    byId("status").textContent = "Connection unavailable";
    byId("status").className = "status failed";
  }
  byId("submit").disabled = !ready;
}
for (const button of document.querySelectorAll("[data-example]")) {
  button.addEventListener("click", () => { byId("prompt").value = button.dataset.example; byId("prompt").focus(); });
}
byId("route-form").addEventListener("submit", async event => {
  event.preventDefault();
  if (busy || !ready) return;
  busy = true;
  byId("response").setAttribute("aria-busy", "true");
  byId("submit").disabled = true;
  byId("submit").textContent = "Routing…";
  byId("error").hidden = true;
  byId("answer-limit").hidden = true;
  byId("answer-limit").textContent = "";
  byId("decision").hidden = true;
  byId("tier").textContent = "RUNNING";
  byId("tier").className = "tag neutral";
  byId("answer").hidden = false;
  byId("answer").textContent = "Generating a response to your prompt…";
  byId("answer").className = "answer empty";
  byId("calls").replaceChildren();
  byId("results").setAttribute("aria-busy", "true");
  const started = Date.now();
  const tick = () => { byId("progress").textContent = "Waiting for judge and answer · " + Math.floor((Date.now() - started) / 1000) + "s"; };
  tick();
  const timer = setInterval(tick, 1000);
  const maxTokens = Number(byId("tokens").value);
  try {
    const response = await fetch("/api/route", {
      method: "POST",
      headers: {"Content-Type": "application/json", "X-Demo-Request": "1"},
      body: JSON.stringify({prompt: byId("prompt").value, max_tokens: maxTokens})
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "Request failed.");
    byId("decision").hidden = false;
    byId("tier").textContent = data.decision.tier.toUpperCase();
    byId("tier").className = "tag" + (data.decision.tier === "capable" ? " purple" : "");
    byId("selected").textContent = data.decision.model;
    byId("reason").textContent = data.decision.reason;
    byId("score").textContent = typeof data.decision.score === "number" ? Math.round(data.decision.score * 100) + "%" : "Unavailable";
    byId("threshold").textContent = typeof data.decision.threshold === "number" ? data.decision.threshold.toFixed(2) : "—";
    byId("elapsed").textContent = (data.latency_ms / 1000).toFixed(1) + "s";
    byId("answer").textContent = data.answer;
    byId("answer").className = "answer";
    const truncated = data.calls.some(call => call.phase === "answer" && call.finish_reason === "length");
    if (truncated) {
      const guidance = maxTokens < Number(byId("tokens").max)
        ? "Increase the answer token limit and submit again for a longer response."
        : "Ask for a shorter answer or split your prompt into smaller tasks.";
      byId("answer-limit").textContent = "Response incomplete: the model reached the " + maxTokens + "-token limit. " + guidance;
      byId("answer-limit").hidden = false;
    }
    byId("progress").textContent = (truncated ? "Incomplete · " : "Complete · ") + data.decision.source;
    for (const call of data.calls) {
      const row = document.createElement("div");
      row.className = "call";
      const title = document.createElement("strong");
      title.textContent = call.phase === "judge" ? "01 JUDGE" : "02 ANSWER";
      row.append(title, document.createTextNode(" · " + (call.latency_ms / 1000).toFixed(1) + "s · " +
        (call.usage.total_tokens ?? "Unknown") + " tokens · " + call.model));
      byId("calls").append(row);
    }
  } catch (error) {
    byId("answer").textContent = "";
    byId("answer").hidden = true;
    byId("error").textContent = error.message || "Connection interrupted. The backend may still be completing the request.";
    byId("error").hidden = false;
    byId("tier").textContent = "FAILED";
    byId("progress").textContent = "Request failed. No automatic browser retry.";
  } finally {
    clearInterval(timer);
    busy = false;
    byId("response").setAttribute("aria-busy", "false");
    byId("results").setAttribute("aria-busy", "false");
    byId("submit").textContent = "Route & answer ↗";
    refreshStatus();
  }
});
refreshStatus();
setInterval(refreshStatus, 30000);
