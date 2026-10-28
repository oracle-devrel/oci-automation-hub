/* Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. */
/* The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ */
const input = document.getElementById("input");
const chatForm = document.getElementById("chatForm");
const sendBtn = document.getElementById("sendBtn");
const newChatBtn = document.getElementById("newChatBtn");
const messagesEl = document.getElementById("messages");
const agentOutputEl = document.getElementById("agentOutput");
const traceOutputEl = document.getElementById("traceOutput");
const typingIndicator = document.getElementById("typingIndicator");
const serversOutputEl = document.getElementById("serversOutput");
const conversationListEl = document.getElementById("conversationList");
const historyStatus = document.getElementById("historyStatus");
const sidebarNewChatBtn = document.getElementById("sidebarNewChatBtn");
const sessionBadge = document.getElementById("sessionBadge");
const userBadge = document.getElementById("userBadge");
const loginLink = document.getElementById("loginLink");
const logoutLink = document.getElementById("logoutLink");
const regionSelect = document.getElementById("regionSelect");
const compartmentSelect = document.getElementById("compartmentSelect");
const projectSelect = document.getElementById("projectSelect");
const modelSelect = document.getElementById("modelSelect");
const temperatureInput = document.getElementById("temperatureInput");
const topPInput = document.getElementById("topPInput");
const maxTokensInput = document.getElementById("maxTokensInput");
const mcpEnabledInput = document.getElementById("mcpEnabledInput");
const mcpStatus = document.getElementById("mcpStatus");
const mcpServerForm = document.getElementById("mcpServerForm");
const mcpServerNameInput = document.getElementById("mcpServerNameInput");
const mcpServerUrlInput = document.getElementById("mcpServerUrlInput");
const addMcpServerBtn = document.getElementById("addMcpServerBtn");
const refreshMcpBtn = document.getElementById("refreshMcpBtn");
const ragEnabledInput = document.getElementById("ragEnabledInput");
const ragStatus = document.getElementById("ragStatus");
const ragSourceForm = document.getElementById("ragSourceForm");
const ragStoreSelect = document.getElementById("ragStoreSelect");
const ragNameInput = document.getElementById("ragNameInput");
const ragFileUploadInput = document.getElementById("ragFileUploadInput");
const uploadRagFilesBtn = document.getElementById("uploadRagFilesBtn");
const ragSelectedFiles = document.getElementById("ragSelectedFiles");
const ragFileIdsInput = document.getElementById("ragFileIdsInput");
const saveRagBtn = document.getElementById("saveRagBtn");
const refreshRagBtn = document.getElementById("refreshRagBtn");
const ragSourceOutput = document.getElementById("ragSourceOutput");

const threadKey = "oci-agent-thread-id";
const historyKey = "oci-agent-history";
const disabledToolsKey = "oci-agent-disabled-tools";
const settingsKey = "oci-agent-ui-settings";
const conversationMapKey = "oci-agent-conversation-map";
const memorySubjectKey = "oci-agent-memory-subject-id";
const panelStateKey = "oci-agent-panel-state";

let threadId = localStorage.getItem(threadKey) || crypto.randomUUID();
let history = JSON.parse(localStorage.getItem(historyKey) || "[]");
let disabledTools = loadSet(disabledToolsKey);
let conversationMap = loadMap(conversationMapKey);
let memorySubjectId = localStorage.getItem(memorySubjectKey) || `subject-${crypto.randomUUID()}`;
let availableToolNames = [];
let mcpServerCatalog = [];
let modelCatalog = [];
let ragSource = null;
let ragStoreCatalog = [];
let currentAssistantBubble = null;
let traceLines = [];
let settings = loadSettings();
let currentUser = null;
let enterpriseAiConfig = {};

localStorage.setItem(threadKey, threadId);
localStorage.setItem(memorySubjectKey, memorySubjectId);
sessionBadge.textContent = `thread: ${threadId}`;

function loadSet(key) {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || "[]");
    return new Set(Array.isArray(parsed) ? parsed.map(String) : []);
  } catch {
    return new Set();
  }
}

function saveSet(key, value) {
  localStorage.setItem(key, JSON.stringify(Array.from(value)));
}

function loadMap(key) {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || "{}");
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveConversationMap() {
  localStorage.setItem(conversationMapKey, JSON.stringify(conversationMap));
}

function getConversationId() {
  return conversationMap[threadId] || "";
}

function setConversationId(value) {
  if (!value) return;
  conversationMap[threadId] = value;
  saveConversationMap();
  sessionBadge.textContent = `thread: ${threadId} | conversation: ${value}`;
}

function currentConversationTitle() {
  const firstUserMessage = history.find((item) => item.role === "user" && item.content.trim());
  return firstUserMessage ? firstUserMessage.content.trim().slice(0, 80) : "New conversation";
}

function selectedOptionText(select) {
  const option = select.options[select.selectedIndex];
  return option ? option.textContent : "";
}

async function apiFetch(url, options = {}) {
  const res = await fetch(url, options);
  if (res.status === 401) {
    loginLink.classList.remove("hidden");
    logoutLink.classList.add("hidden");
    userBadge.textContent = "Sign in required";
    throw new Error("Authentication required");
  }
  return res;
}

async function loadCurrentUser() {
  try {
    const res = await fetch("/api/auth/me");
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to load user");
    currentUser = data.user;
    userBadge.textContent = currentUser.display_name || currentUser.email || currentUser.sub || "OCI user";
    loginLink.classList.toggle("hidden", data.authenticated || !data.auth_configured);
    logoutLink.classList.toggle("hidden", !data.authenticated);
  } catch (err) {
    userBadge.textContent = "Sign in required";
    loginLink.classList.remove("hidden");
    logoutLink.classList.add("hidden");
  }
}

async function saveConversationSnapshot() {
  if (!history.length) return;
  try {
    const res = await apiFetch("/api/conversations", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        thread_id: threadId,
        title: currentConversationTitle(),
        conversation_id: getConversationId(),
        memory_subject_id: memorySubjectId,
        region: regionSelect.value,
        compartment_id: compartmentSelect.value,
        compartment_name: selectedOptionText(compartmentSelect),
        project_id: projectSelect.value,
        project_name: selectedOptionText(projectSelect),
        model_id: modelSelect.value,
        messages: history,
      }),
    });
    if (!res.ok) throw new Error(await res.text());
    await loadConversationList();
  } catch (err) {
    historyStatus.textContent = "Save failed";
    appendTrace(`Conversation save failed: ${err.message}`);
  }
}

async function loadEnterpriseAiConfig() {
  try {
    const res = await apiFetch("/api/enterprise-ai/config");
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to load Enterprise AI config");
    enterpriseAiConfig = data;
    if (data.memory_subject_id) {
      memorySubjectId = data.memory_subject_id;
      localStorage.setItem(memorySubjectKey, memorySubjectId);
    }
  } catch (err) {
    enterpriseAiConfig = {};
    appendTrace(`Enterprise AI config load failed: ${err.message}`);
  }
}

function renderConversationList(items) {
  conversationListEl.innerHTML = "";
  conversationListEl.classList.toggle("empty", items.length === 0);
  historyStatus.textContent = `${items.length} saved`;

  if (items.length === 0) {
    conversationListEl.textContent = "No saved conversations yet.";
    return;
  }

  for (const item of items) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `conversation-item ${item.thread_id === threadId ? "active" : ""}`;
    button.dataset.threadId = item.thread_id;
    button.innerHTML = `
      <span class="conversation-title">${escapeHtml(item.title || "Conversation")}</span>
      <span class="conversation-meta">${escapeHtml(item.project_name || item.model_id || "OCI Enterprise AI")}</span>
    `;
    conversationListEl.appendChild(button);
  }
}

async function loadConversationList() {
  try {
    const res = await apiFetch("/api/conversations");
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.message || "Unable to load conversations");
    renderConversationList(data.conversations || []);
  } catch (err) {
    conversationListEl.className = "conversation-list empty";
    conversationListEl.textContent = `Unable to load conversations: ${err.message}`;
    historyStatus.textContent = "Unavailable";
  }
}

async function loadConversation(threadToLoad) {
  try {
    const res = await apiFetch(`/api/conversations/${encodeURIComponent(threadToLoad)}`);
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to load conversation");

    const conversation = data.conversation;
    threadId = conversation.thread_id;
    localStorage.setItem(threadKey, threadId);
    history = conversation.messages || [];
    saveHistory();

    if (conversation.conversation_id) {
      setConversationId(conversation.conversation_id);
    } else {
      sessionBadge.textContent = `thread: ${threadId}`;
    }

    settings = {
      ...settings,
      region: conversation.region || settings.region,
      compartment_id: conversation.compartment_id || settings.compartment_id,
      project_id: conversation.project_id || settings.project_id,
      model_id: conversation.model_id || settings.model_id,
    };
    localStorage.setItem(settingsKey, JSON.stringify(settings));

    renderHistory();
    resetLivePanels();
    await loadRegions();
    await loadConversationList();
    updateSendState();
  } catch (err) {
    appendTrace(`Conversation load failed: ${err.message}`);
  }
}

function loadSettings() {
  try {
    const parsed = JSON.parse(localStorage.getItem(settingsKey) || "{}");
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveSettings() {
  const selectedModel = getSelectedModel();
  settings = {
    region: regionSelect.value,
    compartment_id: compartmentSelect.value,
    project_id: projectSelect.value,
    model_id: modelSelect.value,
    model_provider: selectedModel.provider || "",
    temperature: numberOrDefault(temperatureInput.value, 0.5),
    top_p: numberOrDefault(topPInput.value, 0.7),
    max_tokens: Math.round(numberOrDefault(maxTokensInput.value, 16000)),
    mcp_enabled: mcpEnabledInput.checked,
    rag_enabled: ragEnabledInput.checked,
  };
  localStorage.setItem(settingsKey, JSON.stringify(settings));
}

function loadPanelState() {
  try {
    const parsed = JSON.parse(localStorage.getItem(panelStateKey) || "{}");
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function savePanelState(state) {
  localStorage.setItem(panelStateKey, JSON.stringify(state));
}

function setPanelCollapsed(panel, collapsed) {
  const button = panel.querySelector("[data-panel-toggle]");
  const title = panel.querySelector(".panel-head h2")?.textContent || "Panel";
  panel.classList.toggle("collapsed", collapsed);
  if (!button) return;
  button.textContent = collapsed ? "▸" : "▾";
  button.setAttribute("aria-expanded", String(!collapsed));
  button.setAttribute("aria-label", `${collapsed ? "Expand" : "Collapse"} ${title}`);
  button.title = `${collapsed ? "Expand" : "Collapse"} ${title}`;
}

function initCollapsiblePanels() {
  const state = loadPanelState();
  document.querySelectorAll(".collapsible-panel").forEach((panel) => {
    const panelId = panel.dataset.panelId;
    const button = panel.querySelector("[data-panel-toggle]");
    if (!panelId || !button) return;

    setPanelCollapsed(panel, Boolean(state[panelId]));
    button.addEventListener("click", () => {
      const nextCollapsed = !panel.classList.contains("collapsed");
      const nextState = loadPanelState();
      nextState[panelId] = nextCollapsed;
      savePanelState(nextState);
      setPanelCollapsed(panel, nextCollapsed);
    });
  });
}

function numberOrDefault(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function getSelectedModel() {
  return modelCatalog.find((model) => model.id === modelSelect.value) || {};
}

function toolKey(serverId, toolName) {
  return `${serverId}::${toolName}`;
}

function getEnabledServerIds() {
  if (!mcpEnabledInput.checked) return [];
  return mcpServerCatalog.filter((server) => server.enabled).map((server) => server.server_id);
}

function getAllowedMcpTools() {
  const allowed = {};
  if (!mcpEnabledInput.checked) return allowed;

  for (const server of mcpServerCatalog) {
    if (!server.enabled) continue;
    const tools = (server.tools || [])
      .map((tool) => String(tool.name || ""))
      .filter((name) => name && !disabledTools.has(toolKey(server.server_id, name)));
    allowed[server.server_id] = tools;
  }
  return allowed;
}

function getEnabledToolNames() {
  return Object.values(getAllowedMcpTools()).flat();
}

function setToolEnabled(serverId, name, enabled) {
  const key = toolKey(serverId, name);
  if (enabled) {
    disabledTools.delete(key);
  } else {
    disabledTools.add(key);
  }
  saveSet(disabledToolsKey, disabledTools);
}

function renderHistory() {
  messagesEl.innerHTML = "";
  if (history.length === 0) {
    messagesEl.innerHTML = '<div class="msg meta">Start a conversation with the selected region, compartment, project, and model.</div>';
    return;
  }

  for (const item of history) {
    const div = document.createElement("div");
    div.className = `msg ${item.role}`;
    div.textContent = item.content;
    messagesEl.appendChild(div);
  }
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

function saveHistory() {
  localStorage.setItem(historyKey, JSON.stringify(history));
}

function addMessage(role, content) {
  history.push({ role, content });
  saveHistory();
  renderHistory();
}

function resetLivePanels() {
  agentOutputEl.className = "output empty";
  agentOutputEl.textContent = "The assistant reply will appear here.";
  traceOutputEl.className = "output empty";
  traceOutputEl.textContent = "Tool activity and request status will appear here.";
  traceLines = [];
  currentAssistantBubble = null;
}

function appendTrace(line) {
  traceLines.push(line);
  traceOutputEl.classList.remove("empty");
  traceOutputEl.textContent = traceLines.map((x, i) => `${i + 1}. ${x}`).join("\n\n");
  traceOutputEl.scrollTop = traceOutputEl.scrollHeight;
}

function ensureAssistantBubble() {
  if (currentAssistantBubble) return currentAssistantBubble;
  currentAssistantBubble = document.createElement("div");
  currentAssistantBubble.className = "msg assistant";
  currentAssistantBubble.textContent = "";
  messagesEl.appendChild(currentAssistantBubble);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return currentAssistantBubble;
}

function appendAssistantDelta(text) {
  const bubble = ensureAssistantBubble();
  bubble.textContent += text;
  messagesEl.scrollTop = messagesEl.scrollHeight;
  agentOutputEl.classList.remove("empty");
  agentOutputEl.textContent = bubble.textContent;
}

function finalizeAssistantMessage() {
  if (!currentAssistantBubble) return;
  const content = currentAssistantBubble.textContent.trim();
  if (content) {
    history.push({ role: "assistant", content });
    saveHistory();
  }
  currentAssistantBubble = null;
  renderHistory();
  saveConversationSnapshot();
}

function setBusy(busy) {
  sendBtn.disabled = busy || input.value.trim().length === 0 || !modelSelect.value || !regionSelect.value || !compartmentSelect.value || !projectSelect.value;
  newChatBtn.disabled = busy;
  input.disabled = busy;
  sendBtn.textContent = busy ? "Sending" : "Send";
  typingIndicator.classList.toggle("hidden", !busy);
}

function updateSendState() {
  if (input.disabled) return;
  sendBtn.disabled = input.value.trim().length === 0 || !modelSelect.value || !regionSelect.value || !compartmentSelect.value || !projectSelect.value;
}

function startNewChat() {
  history = [];
  saveHistory();
  renderHistory();
  input.value = "";

  threadId = crypto.randomUUID();
  localStorage.setItem(threadKey, threadId);
  sessionBadge.textContent = `thread: ${threadId}`;

  resetLivePanels();
  loadConversationList();
  setBusy(false);
  input.focus();
}

function setSelectLoading(select, label) {
  select.innerHTML = "";
  const option = document.createElement("option");
  option.value = "";
  option.textContent = label;
  select.appendChild(option);
}

async function loadRegions() {
  setSelectLoading(regionSelect, "Loading regions...");
  try {
    const res = await apiFetch("/api/oci/regions");
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.message || "Unable to load regions");

    regionSelect.innerHTML = "";
    for (const region of data.regions || []) {
      const option = document.createElement("option");
      option.value = region.id;
      option.textContent = `${region.name} (${region.id})`;
      regionSelect.appendChild(option);
    }

    regionSelect.value = settings.region || data.default_region || regionSelect.options[0]?.value || "";
    await loadCompartments(regionSelect.value);
  } catch (err) {
    setSelectLoading(regionSelect, "Regions unavailable");
    appendTrace(`Region load failed: ${err.message}`);
  }
}

async function loadCompartments(region) {
  setSelectLoading(compartmentSelect, "Loading compartments...");
  setSelectLoading(projectSelect, "Select a compartment first");
  updateSendState();

  if (!region) return;

  try {
    const res = await apiFetch(`/api/oci/compartments?region=${encodeURIComponent(region)}`);
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.message || "Unable to load compartments");

    compartmentSelect.innerHTML = "";
    for (const compartment of data.compartments || []) {
      const option = document.createElement("option");
      option.value = compartment.id;
      option.textContent = compartment.name;
      option.title = compartment.id;
      compartmentSelect.appendChild(option);
    }

    const savedCompartmentExists = Array.from(compartmentSelect.options).some((option) => option.value === settings.compartment_id);
    const defaultCompartmentExists = Array.from(compartmentSelect.options).some((option) => option.value === data.default_compartment_id);
    compartmentSelect.value = savedCompartmentExists
      ? settings.compartment_id
      : defaultCompartmentExists
        ? data.default_compartment_id
        : compartmentSelect.options[0]?.value || "";

    await loadProjects(region, compartmentSelect.value);
  } catch (err) {
    setSelectLoading(compartmentSelect, "Compartments unavailable");
    setSelectLoading(projectSelect, "Projects unavailable");
    appendTrace(`Compartment load failed: ${err.message}`);
  } finally {
    saveSettings();
    updateSendState();
  }
}

async function loadProjects(region, compartmentId) {
  setSelectLoading(projectSelect, "Loading projects...");
  updateSendState();

  if (!region || !compartmentId) return;

  try {
    const res = await apiFetch(`/api/oci/genai-projects?region=${encodeURIComponent(region)}&compartment_id=${encodeURIComponent(compartmentId)}`);
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.message || "Unable to load Gen AI projects");

    projectSelect.innerHTML = "";
    for (const project of data.projects || []) {
      const option = document.createElement("option");
      option.value = project.id;
      option.textContent = project.display_name;
      option.title = project.id;
      projectSelect.appendChild(option);
    }

    const savedProjectExists = Array.from(projectSelect.options).some((option) => option.value === settings.project_id);
    const defaultProjectExists = Array.from(projectSelect.options).some((option) => option.value === data.default_project_id);
    projectSelect.value = savedProjectExists
      ? settings.project_id
      : defaultProjectExists
        ? data.default_project_id
        : projectSelect.options[0]?.value || "";

    if (!projectSelect.value) {
      setSelectLoading(projectSelect, "No active projects found");
      projectSelect.value = "";
    }
    appendTrace(`Loaded ${(data.projects || []).length} Gen AI project(s) for the selected compartment.`);
    await loadModels(region, projectSelect.value, compartmentSelect.value);
    await loadRagSource();
  } catch (err) {
    setSelectLoading(projectSelect, "Projects unavailable");
    setSelectLoading(modelSelect, "Select a project first");
    renderRagSource(null);
    appendTrace(`Gen AI project load failed: ${err.message}`);
  } finally {
    saveSettings();
    updateSendState();
  }
}

async function loadModels(region, projectId = projectSelect.value, compartmentId = compartmentSelect.value) {
  setSelectLoading(modelSelect, "Loading models...");
  modelCatalog = [];
  updateSendState();

  if (!region || !compartmentId || !projectId) {
    setSelectLoading(modelSelect, "Select a project first");
    return;
  }

  try {
    const params = new URLSearchParams({
      region,
      compartment_id: compartmentId,
      project_id: projectId,
    });
    const res = await apiFetch(`/api/oci/models?${params.toString()}`);
    const data = await res.json();
    if (!res.ok) throw new Error(data.message || "Unable to load models");

    modelCatalog = data.models || [];
    modelSelect.innerHTML = "";

    for (const model of modelCatalog) {
      const option = document.createElement("option");
      option.value = model.id;
      option.textContent = model.display_name && model.display_name !== model.id
        ? `${model.display_name} (${model.id})`
        : model.id;
      modelSelect.appendChild(option);
    }

    const savedModelExists = modelCatalog.some((model) => model.id === settings.model_id);
    modelSelect.value = savedModelExists ? settings.model_id : modelCatalog[0]?.id || "";
    if (!modelSelect.value) {
      setSelectLoading(modelSelect, "No supported on-demand models found");
    }
    appendTrace(`Loaded ${modelCatalog.length} supported on-demand model option(s) for ${region}.`);
  } catch (err) {
    setSelectLoading(modelSelect, "Models unavailable");
    appendTrace(`Model load failed: ${err.message}`);
  } finally {
    saveSettings();
    updateSendState();
  }
}

function parseRagFileIds() {
  return ragFileIdsInput.value
    .split(/[\n,]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function setRagFileIds(fileIds) {
  ragFileIdsInput.value = Array.from(new Set(fileIds.filter(Boolean))).join("\n");
}

function renderRagStoreOptions(stores, selectedId = "") {
  ragStoreCatalog = stores || [];
  ragStoreSelect.innerHTML = "";

  const createOption = document.createElement("option");
  createOption.value = "";
  createOption.textContent = "Create new RAG source";
  ragStoreSelect.appendChild(createOption);

  for (const store of ragStoreCatalog) {
    const option = document.createElement("option");
    option.value = store.id;
    option.textContent = store.name && store.name !== store.id ? `${store.name} (${store.id})` : store.id;
    ragStoreSelect.appendChild(option);
  }

  const exists = ragStoreCatalog.some((store) => store.id === selectedId);
  ragStoreSelect.value = exists ? selectedId : "";
}

function renderRagSource(source) {
  ragSource = source || null;
  const enabled = Boolean(ragSource && ragEnabledInput.checked);
  const fileCount = ragSource
    ? Number.isFinite(Number(ragSource.file_count))
      ? Number(ragSource.file_count)
      : (ragSource.file_ids || []).length
    : 0;
  ragEnabledInput.disabled = !ragSource;
  ragStatus.textContent = ragSource
    ? `${enabled ? "Enabled" : "Ready"} · ${fileCount} file(s)`
    : "Not configured";

  if (!ragSource) {
    ragFileIdsInput.value = "";
    ragNameInput.value = ragNameInput.value || "OCI chat RAG source";
    ragSourceOutput.className = "rag-output empty";
    ragSourceOutput.textContent = ragStoreCatalog.length
      ? "Choose an existing RAG source or create a new one."
      : "No existing RAG sources found. Enter a name to create one.";
    return;
  }

  ragNameInput.value = ragSource.name || ragNameInput.value || "OCI chat RAG source";
  setRagFileIds(ragSource.file_ids || []);
  ragSourceOutput.className = "rag-output";
  ragSourceOutput.textContent = [
    `Vector store: ${ragSource.vector_store_id}`,
    `Files: ${fileCount}${ragSource.file_count_source ? ` (${ragSource.file_count_source})` : ""}`,
    ragSource.file_count_error ? `File count warning: ${ragSource.file_count_error}` : "",
    `Updated: ${ragSource.updated_at || "unknown"}`,
  ].filter(Boolean).join("\n");
}

async function loadRagSource() {
  const region = regionSelect.value;
  const compartmentId = compartmentSelect.value;
  const projectId = projectSelect.value;
  ragSource = null;

  if (!region || !compartmentId || !projectId) {
    renderRagStoreOptions([], "");
    renderRagSource(null);
    ragSourceOutput.textContent = "Select a project to load its RAG source.";
    return;
  }

  try {
    const url = `/api/rag-source?region=${encodeURIComponent(region)}&compartment_id=${encodeURIComponent(compartmentId)}&project_id=${encodeURIComponent(projectId)}`;
    const res = await apiFetch(url);
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to load RAG source");
    renderRagStoreOptions(data.vector_stores || [], data.source?.vector_store_id || "");
    renderRagSource(data.source);
    if (data.vector_store_error) {
      ragStatus.textContent = "List failed";
      ragSourceOutput.className = "rag-output empty";
      ragSourceOutput.textContent = `Could not list existing RAG sources: ${data.vector_store_error}`;
    }
  } catch (err) {
    ragStatus.textContent = "Unavailable";
    ragSourceOutput.className = "rag-output empty";
    ragSourceOutput.textContent = `RAG source load failed: ${err.message}`;
  } finally {
    updateSendState();
  }
}

async function saveRagSource() {
  if (!regionSelect.value || !compartmentSelect.value || !projectSelect.value) return;

  saveRagBtn.disabled = true;
  ragSourceOutput.className = "rag-output empty";
  ragSourceOutput.textContent = ragSource ? "Updating RAG source..." : "Creating RAG source...";
  try {
    const res = await apiFetch("/api/rag-source", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        region: regionSelect.value,
        compartment_id: compartmentSelect.value,
        project_id: projectSelect.value,
        name: ragNameInput.value.trim() || "OCI chat RAG source",
        vector_store_id: ragStoreSelect.value,
        file_ids: parseRagFileIds(),
      }),
    });
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to save RAG source");
    ragEnabledInput.checked = true;
    renderRagSource(data.source);
    saveSettings();
    appendTrace(`${data.created ? "Created" : "Selected"} RAG source; attached ${data.attached_file_count || 0} new file(s).`);
  } catch (err) {
    ragStatus.textContent = "Save failed";
    ragSourceOutput.className = "rag-output empty";
    ragSourceOutput.textContent = `RAG source save failed: ${err.message}`;
  } finally {
    saveRagBtn.disabled = false;
    updateSendState();
  }
}

async function uploadRagFiles() {
  if (!regionSelect.value || !compartmentSelect.value || !projectSelect.value) return;
  const files = Array.from(ragFileUploadInput.files || []);
  if (!files.length) {
    ragSourceOutput.className = "rag-output empty";
    ragSourceOutput.textContent = "Choose one or more files first.";
    return;
  }

  uploadRagFilesBtn.disabled = true;
  ragSourceOutput.className = "rag-output empty";
  ragSourceOutput.textContent = `Uploading ${files.length} file(s)...`;
  try {
    const formData = new FormData();
    formData.append("region", regionSelect.value);
    formData.append("compartment_id", compartmentSelect.value);
    formData.append("project_id", projectSelect.value);
    formData.append("name", ragNameInput.value.trim() || "OCI chat RAG source");
    formData.append("vector_store_id", ragStoreSelect.value || ragSource?.vector_store_id || "");
    for (const file of files) formData.append("files", file);

    const res = await apiFetch("/api/rag-files", {
      method: "POST",
      body: formData,
    });
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to upload file");

    const uploadedIds = (data.files || []).map((file) => file.id).filter(Boolean);
    ragFileUploadInput.value = "";
    ragSelectedFiles.textContent = "No file selected";
    ragEnabledInput.checked = true;
    if (data.source) {
      renderRagStoreOptions(ragStoreCatalog, data.source.vector_store_id);
      renderRagSource(data.source);
    } else {
      setRagFileIds([...parseRagFileIds(), ...uploadedIds]);
    }
    saveSettings();
    appendTrace(`Uploaded ${uploadedIds.length} RAG file(s); attached ${data.attached_file_count || 0} to vector store.`);
  } catch (err) {
    ragStatus.textContent = "Upload failed";
    ragSourceOutput.className = "rag-output empty";
    ragSourceOutput.textContent = `RAG file upload failed: ${err.message}`;
  } finally {
    uploadRagFilesBtn.disabled = false;
  }
}

function updateSelectedRagFiles() {
  const files = Array.from(ragFileUploadInput.files || []);
  if (!files.length) {
    ragSelectedFiles.textContent = "No file selected";
    return;
  }
  if (files.length === 1) {
    ragSelectedFiles.textContent = files[0].name;
    return;
  }
  ragSelectedFiles.textContent = `${files.length} files selected`;
}

function renderMcpServer(server) {
  const card = document.createElement("article");
  card.className = "server-card";
  card.dataset.serverId = server.server_id;

  const tools = server.tools || [];
  const serverHeader = document.createElement("div");
  serverHeader.className = "server-summary";
  serverHeader.innerHTML = `
    <details class="server-details" open>
      <summary>
        <strong>${escapeHtml(server.name || "MCP server")}</strong>
        <div class="server-url">${escapeHtml(server.url || "")}</div>
        ${server.error ? `<div class="server-error">${escapeHtml(server.error)}</div>` : ""}
      </summary>
    </details>
    <div class="server-actions">
      <span class="pill">${tools.length} tools</span>
      <label class="switch" title="Enable or disable ${escapeHtml(server.name || "server")}">
        <input type="checkbox" ${server.enabled ? "checked" : ""} data-server-toggle="${escapeHtml(server.server_id)}" />
        <span></span>
      </label>
      <button class="icon-button danger-button" type="button" title="Remove MCP server" data-server-remove="${escapeHtml(server.server_id)}">×</button>
    </div>
  `;

  const toolList = document.createElement("div");
  toolList.className = "tool-list";

  if (tools.length === 0) {
    toolList.innerHTML = '<div class="empty">No tools available for this server.</div>';
  }

  for (const tool of tools) {
    const toolName = String(tool.name || "tool");
    const enabled = !disabledTools.has(toolKey(server.server_id, toolName));

    const toolEl = document.createElement("section");
    toolEl.className = "tool";
    toolEl.innerHTML = `
      <h3>${escapeHtml(toolName)}</h3>
      <label class="switch" title="Enable or disable ${escapeHtml(toolName)}">
        <input type="checkbox" ${enabled ? "checked" : ""} data-server-tool="${escapeHtml(server.server_id)}" data-tool="${escapeHtml(toolName)}" />
        <span></span>
      </label>
    `;
    toolList.appendChild(toolEl);
  }

  card.appendChild(serverHeader);
  card.appendChild(toolList);
  return card;
}

async function loadMcpServers() {
  try {
    const res = await apiFetch("/api/mcp-info");
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.message || "Failed to load MCP info");

    const servers = data.servers || [];
    mcpServerCatalog = servers;
    availableToolNames = servers.flatMap((server) => (server.tools || []).map((tool) => toolKey(server.server_id, String(tool.name || ""))).filter(Boolean));
    disabledTools = new Set(Array.from(disabledTools).filter((name) => availableToolNames.includes(name)));
    saveSet(disabledToolsKey, disabledTools);

    serversOutputEl.innerHTML = "";
    serversOutputEl.classList.toggle("empty", servers.length === 0);
    if (servers.length === 0) {
      serversOutputEl.textContent = "No connected MCP servers found.";
    } else {
      for (const server of servers) serversOutputEl.appendChild(renderMcpServer(server));
    }
    syncMcpState();
  } catch (err) {
    serversOutputEl.className = "server-list empty";
    serversOutputEl.textContent = `Unable to load MCP servers: ${err.message}`;
    availableToolNames = [];
    mcpServerCatalog = [];
    syncMcpState();
  }
}

function syncMcpState() {
  const enabled = mcpEnabledInput.checked;
  mcpStatus.textContent = enabled ? `${getEnabledToolNames().length} enabled tools` : "Disabled";
  serversOutputEl.classList.toggle("empty", !enabled);
  serversOutputEl.querySelectorAll('input[type="checkbox"]').forEach((checkbox) => {
    checkbox.disabled = !enabled;
  });
  refreshMcpBtn.disabled = !enabled;
  addMcpServerBtn.disabled = !enabled;
  mcpServerNameInput.disabled = !enabled;
  mcpServerUrlInput.disabled = !enabled;
  saveSettings();
}

async function addMcpServer() {
  const name = mcpServerNameInput.value.trim();
  const url = mcpServerUrlInput.value.trim();
  if (!name || !url) return;

  addMcpServerBtn.disabled = true;
  appendTrace(`Adding MCP server: ${name}`);
  try {
    const res = await apiFetch("/api/mcp-servers", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, url, enabled: true }),
    });
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to add MCP server");
    mcpServerNameInput.value = "";
    mcpServerUrlInput.value = "";
    if (data.server.error) {
      appendTrace(`Added ${data.server.name}, but tool discovery failed: ${data.server.error}`);
    } else {
      appendTrace(`Discovered ${(data.server.tools || []).length} tool(s) on ${data.server.name}.`);
    }
    await loadMcpServers();
  } catch (err) {
    appendTrace(`MCP server add failed: ${err.message}`);
  } finally {
    addMcpServerBtn.disabled = !mcpEnabledInput.checked;
  }
}

async function setMcpServerEnabled(serverId, enabled) {
  try {
    const res = await apiFetch(`/api/mcp-servers/${encodeURIComponent(serverId)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled }),
    });
    const data = await res.json();
    if (!res.ok || data.status !== "success") throw new Error(data.detail || data.message || "Unable to update MCP server");
    await loadMcpServers();
  } catch (err) {
    appendTrace(`MCP server update failed: ${err.message}`);
    await loadMcpServers();
  }
}

async function removeMcpServer(serverId) {
  try {
    const res = await apiFetch(`/api/mcp-servers/${encodeURIComponent(serverId)}`, { method: "DELETE" });
    if (!res.ok) throw new Error(await res.text());
    disabledTools = new Set(Array.from(disabledTools).filter((name) => !name.startsWith(`${serverId}::`)));
    saveSet(disabledToolsKey, disabledTools);
    await loadMcpServers();
  } catch (err) {
    appendTrace(`MCP server remove failed: ${err.message}`);
  }
}

function currentPayload(text) {
  const selectedModel = getSelectedModel();
  return {
    text,
    thread_id: threadId,
    history: history.slice(0, -1),
    region: regionSelect.value,
    compartment_id: compartmentSelect.value,
    project_id: projectSelect.value,
    model_id: modelSelect.value,
    model_provider: selectedModel.provider || settings.model_provider || "",
    temperature: numberOrDefault(temperatureInput.value, 0.5),
    top_p: numberOrDefault(topPInput.value, 0.7),
    max_tokens: Math.round(numberOrDefault(maxTokensInput.value, 16000)),
    mcp_enabled: mcpEnabledInput.checked,
    enabled_mcp_servers: getEnabledServerIds(),
    allowed_mcp_tools: getAllowedMcpTools(),
    allowed_tools: getEnabledToolNames(),
    conversation_id: getConversationId(),
    memory_subject_id: memorySubjectId,
    memory_access_policy: enterpriseAiConfig.memory_access_policy || "",
    rag_enabled: Boolean(ragEnabledInput.checked && ragSource?.vector_store_id),
    rag_vector_store_id: ragSource?.vector_store_id || "",
    rag_max_results: 6,
  };
}

async function sendMessage() {
  const text = input.value.trim();
  if (!text || !modelSelect.value || !regionSelect.value || !compartmentSelect.value || !projectSelect.value) return;

  saveSettings();
  addMessage("user", text);
  saveConversationSnapshot();
  input.value = "";
  setBusy(true);
  resetLivePanels();

  try {
    const res = await apiFetch("/api/chat/stream", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(currentPayload(text)),
    });

    if (!res.ok || !res.body) {
      const body = await res.text();
      throw new Error(body || "Streaming request failed");
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      while (true) {
        const splitIndex = buffer.indexOf("\n\n");
        if (splitIndex === -1) break;

        const rawEvent = buffer.slice(0, splitIndex);
        buffer = buffer.slice(splitIndex + 2);
        handleStreamEvent(rawEvent);
      }
    }

    finalizeAssistantMessage();
  } catch (err) {
    const msg = `Error: ${err.message}`;
    addMessage("assistant", msg);
    saveConversationSnapshot();
    agentOutputEl.classList.remove("empty");
    agentOutputEl.textContent = msg;
    traceOutputEl.classList.remove("empty");
    traceOutputEl.textContent = msg;
  } finally {
    setBusy(false);
    input.focus();
  }
}

function handleStreamEvent(rawEvent) {
  const lines = rawEvent.split("\n");
  let eventName = "message";
  let dataText = "";

  for (const line of lines) {
    if (line.startsWith("event:")) {
      eventName = line.slice(6).trim();
    } else if (line.startsWith("data:")) {
      dataText += line.slice(5).trim();
    }
  }

  let payload = {};
  try {
    payload = dataText ? JSON.parse(dataText) : {};
  } catch {
    payload = { text: dataText };
  }

  if (eventName === "status") {
    appendTrace(`Status: ${payload.message || "update"}`);
  } else if (eventName === "conversation") {
    setConversationId(payload.conversation_id);
    saveConversationSnapshot();
    appendTrace(`Conversation: ${payload.conversation_id || "created"}`);
  } else if (eventName === "tools") {
    const mcpText = payload.enabled === false
      ? "MCP disabled for this turn"
      : `Connected to MCP with ${payload.tool_count || 0} enabled tools`;
    const ragText = payload.rag_enabled
      ? `RAG file_search enabled for ${payload.rag_vector_store_id}`
      : "RAG file_search disabled";
    appendTrace(`${mcpText}; ${ragText}`);
  } else if (eventName === "trace") {
    appendTrace(payload.line || "trace event");
  } else if (eventName === "delta") {
    appendAssistantDelta(payload.text || "");
  } else if (eventName === "done") {
    setConversationId(payload.conversation_id);
    if (payload.reply) {
      const bubble = ensureAssistantBubble();
      bubble.textContent = payload.reply;
      agentOutputEl.classList.remove("empty");
      agentOutputEl.textContent = payload.reply;
    }
    if (Array.isArray(payload.trace) && payload.trace.length) {
      traceLines = payload.trace;
      traceOutputEl.classList.remove("empty");
      traceOutputEl.textContent = traceLines.map((x, i) => `${i + 1}. ${x}`).join("\n\n");
    }
  } else if (eventName === "error") {
    const msg = payload.message || "Unknown streaming error";
    appendTrace(`ERROR: ${msg}`);
    throw new Error(msg);
  }
}

chatForm.addEventListener("submit", (event) => {
  event.preventDefault();
  sendMessage();
});

newChatBtn.addEventListener("click", startNewChat);

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    sendMessage();
  }
});

input.addEventListener("input", updateSendState);

regionSelect.addEventListener("change", async () => {
  saveSettings();
  await loadCompartments(regionSelect.value);
});

compartmentSelect.addEventListener("change", async () => {
  saveSettings();
  await loadProjects(regionSelect.value, compartmentSelect.value);
});

projectSelect.addEventListener("change", async () => {
  saveSettings();
  await loadModels(regionSelect.value, projectSelect.value, compartmentSelect.value);
  await loadRagSource();
  updateSendState();
});

modelSelect.addEventListener("change", () => {
  saveSettings();
  updateSendState();
});

[temperatureInput, topPInput, maxTokensInput].forEach((el) => {
  el.addEventListener("change", saveSettings);
});

mcpEnabledInput.addEventListener("change", syncMcpState);
refreshMcpBtn.addEventListener("click", loadMcpServers);
mcpServerForm.addEventListener("submit", (event) => {
  event.preventDefault();
  addMcpServer();
});
ragEnabledInput.addEventListener("change", () => {
  saveSettings();
  renderRagSource(ragSource);
});
ragStoreSelect.addEventListener("change", () => {
  if (!ragStoreSelect.value) {
    ragSource = null;
    ragNameInput.disabled = false;
    ragEnabledInput.disabled = true;
    ragStatus.textContent = "Not configured";
    ragSourceOutput.className = "rag-output empty";
    ragSourceOutput.textContent = ragStoreCatalog.length
      ? "Choose an existing RAG source or create a new one."
      : "No existing RAG sources found. Enter a name to create one.";
    return;
  }
  const selectedStore = ragStoreCatalog.find((store) => store.id === ragStoreSelect.value);
  ragNameInput.value = selectedStore?.name || ragNameInput.value || "OCI chat RAG source";
  ragNameInput.disabled = false;
  ragSourceOutput.className = "rag-output empty";
  ragSourceOutput.textContent = `Selected vector store: ${ragStoreSelect.value}`;
});
refreshRagBtn.addEventListener("click", loadRagSource);
uploadRagFilesBtn.addEventListener("click", uploadRagFiles);
ragFileUploadInput.addEventListener("change", updateSelectedRagFiles);
ragSourceForm.addEventListener("submit", (event) => {
  event.preventDefault();
  saveRagSource();
});

serversOutputEl.addEventListener("change", (event) => {
  const target = event.target;
  if (target.matches('input[type="checkbox"][data-server-toggle]')) {
    setMcpServerEnabled(target.dataset.serverToggle, target.checked);
    return;
  }
  if (!target.matches('input[type="checkbox"][data-tool][data-server-tool]')) return;
  setToolEnabled(target.dataset.serverTool, target.dataset.tool, target.checked);
  syncMcpState();
});

serversOutputEl.addEventListener("click", (event) => {
  const button = event.target.closest("[data-server-remove]");
  if (!button) return;
  removeMcpServer(button.dataset.serverRemove);
});

conversationListEl.addEventListener("click", (event) => {
  const item = event.target.closest(".conversation-item");
  if (!item) return;
  loadConversation(item.dataset.threadId);
});

sidebarNewChatBtn.addEventListener("click", startNewChat);
initCollapsiblePanels();

temperatureInput.value = settings.temperature ?? "0.5";
topPInput.value = settings.top_p ?? "0.7";
maxTokensInput.value = settings.max_tokens ?? "16000";
mcpEnabledInput.checked = settings.mcp_enabled ?? true;
ragEnabledInput.checked = settings.rag_enabled ?? false;

async function initApp() {
  await loadCurrentUser();
  await loadEnterpriseAiConfig();
  renderHistory();
  resetLivePanels();
  setConversationId(getConversationId());
  updateSendState();
  await loadRegions();
  await loadConversationList();
  loadMcpServers();
}

initApp();
