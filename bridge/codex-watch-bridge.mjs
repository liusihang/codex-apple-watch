#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { execFile, execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const port = Number(process.env.CODEX_WATCH_PORT || 17842);
const host = process.env.CODEX_WATCH_HOST || "::";
const audioDir = path.join(process.cwd(), ".codex-watch", "audio");
const defaultCodexSessionsDir = path.join(os.homedir(), ".codex", "sessions");
const codexAPIBaseURL = (process.env.CODEX_WATCH_CODEX_API_BASE_URL || "https://chatgpt.com/backend-api")
  .replace(/\/+$/, "");
const defaultTranscriptionModel = "gpt-4o-mini-transcribe";
const showNetworkHints = process.env.CODEX_WATCH_SHOW_NETWORK_HINTS === "1";
const verboseBridgeLogging = process.env.CODEX_WATCH_VERBOSE === "1";
let codexAppServer = null;
const clients = new Set();
const httpClients = new Map();
const durableStateBySelection = new Map();
const readStateSignaturesBySelection = new Map();
const sessionFileByThread = new Map();
let latestDurableState = null;

export function createBridgeServer() {
  const authToken = (process.env.CODEX_WATCH_AUTH_TOKEN || "").trim();
  const server = http.createServer(async (request, response) => {
    const requestURL = new URL(request.url || "/", "http://localhost");

    if (requestURL.pathname === "/") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({
        ok: true,
        endpoint: "/codex-watch",
        clients: clients.size,
        port: boundPort(server)
      }));
      return;
    }

    if (requestURL.pathname === "/codex-watch/message" && request.method === "POST") {
      if (!isAuthorizedRequest(request, authToken)) {
        unauthorizedJSONResponse(response);
        return;
      }
      try {
        const client = getHTTPClient(clientIDFromURL(requestURL), request.socket);
        const message = JSON.parse(await readRequestBody(request));
        handleText(client, JSON.stringify(message));
        jsonResponse(response, 200, { ok: true, messages: drainQueuedMessages(client) });
      } catch (error) {
        jsonResponse(response, 400, { ok: false, error: error.message });
      }
      return;
    }

    if (requestURL.pathname === "/codex-watch/poll" && request.method === "GET") {
      if (!isAuthorizedRequest(request, authToken)) {
        unauthorizedJSONResponse(response);
        return;
      }
      const client = getHTTPClient(clientIDFromURL(requestURL), request.socket);
      jsonResponse(response, 200, { ok: true, messages: drainQueuedMessages(client) });
      return;
    }

    response.writeHead(404);
    response.end();
  });

  server.on("upgrade", (request, socket) => {
    const requestURL = new URL(request.url || "/", "http://localhost");
    if (requestURL.pathname !== "/codex-watch") {
      socket.destroy();
      return;
    }
    if (!isAuthorizedRequest(request, authToken)) {
      socket.end([
        "HTTP/1.1 401 Unauthorized",
        'WWW-Authenticate: Bearer realm="codex-watch"',
        "Connection: close",
        "Content-Length: 0",
        "",
        ""
      ].join("\r\n"));
      return;
    }

    const key = request.headers["sec-websocket-key"];
    if (typeof key !== "string") {
      socket.destroy();
      return;
    }

    const accept = crypto
      .createHash("sha1")
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");

    socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      "",
      ""
    ].join("\r\n"));

    const client = {
      socket,
      buffer: Buffer.alloc(0),
      audioStream: null,
      audioPath: null,
      audioBytes: 0,
      audioSampleRate: 48000,
      audioChannels: 1,
      pet: "codex",
      capabilities: [],
      selection: {
        target: "chat",
        project: "project-1",
        chat: "chat-1",
        projectIndex: 0,
        chatIndex: 0,
        newChat: false
      },
      pickerItems: loadCodexPickerItems()
    };
    clients.add(client);
    logConnection("watch connected", socket);

    send(client, {
      type: "state",
      pet: "codex",
      state: "idle",
      title: "Codex",
      body: "Bridge linked",
      items: client.pickerItems,
      ...client.selection
    });

    socket.on("data", chunk => {
      client.buffer = Buffer.concat([client.buffer, chunk]);
      drainFrames(client);
    });
    socket.on("close", () => closeClient(client));
    socket.on("error", () => closeClient(client));
  });

  return server;
}

export function startBridge({ port: listenPort = port, host: listenHost = host } = {}) {
  fs.mkdirSync(audioDir, { recursive: true });
  const server = createBridgeServer();
  server.listen(listenPort, listenHost, () => {
    const activePort = boundPort(server);
    console.log(`Codex Watch bridge listening on port ${activePort} at /codex-watch`);
    if (showNetworkHints) {
      console.log(`LAN URL: ws://${lanAddress()}:${activePort}/codex-watch`);
      console.log(`Hostname URL: ws://${localHostName()}.local:${activePort}/codex-watch`);
      console.log(`Simulator URL: ws://127.0.0.1:${activePort}/codex-watch`);
    } else {
      console.log("Set CODEX_WATCH_SHOW_NETWORK_HINTS=1 to print connection URLs.");
    }
  });
  return server;
}

if (isMainModule()) {
  startBridge();
}

function drainFrames(client) {
  while (client.buffer.length >= 2) {
    const first = client.buffer[0];
    const opcode = first & 0x0f;
    const second = client.buffer[1];
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let offset = 2;

    if (length === 126) {
      if (client.buffer.length < offset + 2) return;
      length = client.buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (client.buffer.length < offset + 8) return;
      const bigLength = client.buffer.readBigUInt64BE(offset);
      if (bigLength > BigInt(Number.MAX_SAFE_INTEGER)) {
        client.socket.destroy();
        return;
      }
      length = Number(bigLength);
      offset += 8;
    }

    let maskKey = null;
    if (masked) {
      maskKey = client.buffer.subarray(offset, offset + 4);
      offset += 4;
    }
    if (client.buffer.length < offset + length) return;

    let payload = client.buffer.subarray(offset, offset + length);
    client.buffer = client.buffer.subarray(offset + length);

    if (maskKey) {
      const unmasked = Buffer.alloc(payload.length);
      for (let index = 0; index < payload.length; index += 1) {
        unmasked[index] = payload[index] ^ maskKey[index % 4];
      }
      payload = unmasked;
    }

    if (opcode === 0x8) {
      closeClient(client, { replyClose: true });
      return;
    }
    if (opcode === 0x1) {
      handleText(client, payload.toString("utf8"));
    }
  }
}

function handleText(client, text) {
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    send(client, { type: "error", body: "Invalid JSON" });
    return;
  }
  if (typeof message.pet === "string" && message.pet.length > 0) {
    client.pet = message.pet;
  }
  updateClientSelection(client, message);
  if (Array.isArray(message.capabilities)) {
    client.capabilities = message.capabilities.filter(value => typeof value === "string");
  }

  switch (message.type) {
    case "hello":
      console.log("hello", client.pet, client.capabilities.join(",") || "no-capabilities");
      maybeOpenCodex();
      resolveClientSelection(client);
      send(client, replayStateForClient(client) ?? {
        type: "state",
        pet: client.pet,
        state: "idle",
        title: "Codex",
        body: "Bridge ready",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      refreshClientStateFromCodex(client).catch(error => {
        warnBridge("state refresh failed", error);
      });
      break;
    case "state":
    case "pet-selected":
      console.log(message.type, client.pet, message.state || "idle");
      broadcast({
        type: "state",
        pet: client.pet,
        state: message.state || "idle",
        title: typeof message.title === "string" ? message.title : "Codex",
        body: typeof message.body === "string" ? message.body : "Pet synced",
        text: typeof message.text === "string" ? message.text : undefined,
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "picker-items":
      updateClientPickerItems(client, message);
      broadcast({
        type: "picker-items",
        pet: client.pet,
        state: message.state || "idle",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "picker-opened":
      console.log("picker-opened", client.selection.target);
      client.pickerItems = loadCodexPickerItems();
      resolveClientSelection(client);
      send(client, {
        type: "picker-items",
        pet: client.pet,
        state: message.state || "idle",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "selection-focus":
    case "project-selected":
    case "chat-selected":
      handleSelection(client, message);
      break;
    case "chat-opened":
      handleChatOpened(client, message).catch(error => {
        warnBridge("chat history failed", error);
        send(client, {
          type: "conversation",
          pet: client.pet,
          title: typeof message.title === "string" ? message.title : "Conversation",
          body: error.message,
          entries: [],
          hasMore: false,
          capabilities: client.capabilities,
          items: client.pickerItems,
          ...client.selection
        });
      });
      break;
    case "mic-start":
      console.log("mic-start", client.pet);
      startAudio(client, message);
      break;
    case "mic-chunk":
      appendAudio(client, message);
      break;
    case "mic-stop":
      console.log("mic-stop");
      stopAudio(client);
      break;
    case "transcript":
      console.log("transcript", `${String(message.text || message.body || "").length} chars`);
      broadcast({
        type: "transcript",
        pet: client.pet,
        state: "review",
        title: typeof message.title === "string" ? message.title : "Transcript",
        body: typeof message.body === "string" ? message.body : message.text,
        text: typeof message.text === "string" ? message.text : message.body,
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
      break;
    case "transcript-send":
      handleTranscriptSend(client, message);
      break;
    case "message-read":
      clearDurableStateForClient(client);
      break;
    case "transcribe-again":
      console.log("transcribe-again");
      sendTranscribingState(client, {
        bytes: Number.isInteger(message.bytes) ? message.bytes : 0,
        savedPath: null
      });
      break;
    case "ping":
      send(client, { type: "pong" });
      break;
    default:
      send(client, { type: "error", body: `Unknown message type: ${message.type}` });
  }
}

function startAudio(client, message) {
  if (client.audioStream) {
    stopAudio(client);
  }

  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const rawPath = path.join(audioDir, `${stamp}.pcm-f32le.raw`);
  const metaPath = path.join(audioDir, `${stamp}.json`);
  fs.writeFileSync(metaPath, JSON.stringify({
    createdAt: new Date().toISOString(),
    sampleRate: message.sampleRate || null,
    channels: message.channels || null,
    encoding: "pcm-f32le"
  }, null, 2));

  client.audioPath = rawPath;
  client.audioBytes = 0;
  client.audioSampleRate = Number(message.sampleRate) || 48000;
  client.audioChannels = Number(message.channels) || 1;
  client.audioStream = fs.createWriteStream(rawPath);
  broadcast({
    type: "state",
    pet: client.pet,
    state: "running",
    title: "Listening",
    body: "Audio streaming",
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

function appendAudio(client, message) {
  if (!client.audioStream || typeof message.data !== "string") {
    return;
  }
  if (Number(message.sampleRate) > 0) {
    client.audioSampleRate = Number(message.sampleRate);
  }
  if (Number.isInteger(message.channels) && message.channels > 0) {
    client.audioChannels = message.channels;
  }
  const chunk = Buffer.from(message.data, "base64");
  client.audioBytes += chunk.length;
  client.audioStream.write(chunk);
}

function stopAudio(client) {
  if (!client.audioStream) {
    return;
  }
  const stream = client.audioStream;
  const savedPath = client.audioPath;
  const bytes = client.audioBytes;
  const sampleRate = client.audioSampleRate || 48000;
  const channels = client.audioChannels || 1;

  client.audioStream = null;
  client.audioPath = null;
  client.audioBytes = 0;
  client.audioSampleRate = 48000;
  client.audioChannels = 1;
  stream.end(() => {
    sendTranscribingState(client, { bytes, savedPath });
    transcribeSavedAudio(client, { bytes, savedPath, sampleRate, channels }).catch(error => {
      errorBridge("transcription failed", error);
      sendTranscriptionFailure(client, error);
    });
  });
}

function sendTranscribingState(client, { bytes, savedPath }) {
  send(client, {
    type: "state",
    pet: client.pet,
    state: "running",
    title: "Transcribing",
    body: "Processing audio",
    bytes,
    path: savedPath,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

async function transcribeSavedAudio(client, { bytes, savedPath, sampleRate, channels }) {
  if (!savedPath || bytes <= 0) {
    throw new Error("No watch audio was received.");
  }

  const wavPath = savedPath.replace(/\.pcm-f32le\.raw$/, ".wav");
  writePCMFloat32Wav(savedPath, wavPath, { sampleRate, channels });
  const text = await transcribeAudio(wavPath);
  const trimmed = text.trim();
  if (!trimmed) {
    throw new Error("Transcription returned no text.");
  }

  send(client, {
    type: "transcript",
    pet: client.pet,
    state: "review",
    title: "Transcript",
    body: trimmed,
    text: trimmed,
    bytes,
    path: wavPath,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

function handleTranscriptSend(client, message) {
  const text = String(message.text || message.body || "").trim();
  console.log("transcript-send", `${text.length} chars`);

  if (!text) {
    sendTranscriptSendFailure(client, new Error("Transcript was empty."));
    return;
  }

  const target = resolveTranscriptTarget(client, message);
  if (!target) {
    sendTranscriptSendFailure(client, new Error("Pick a Codex chat before sending."));
    return;
  }

  send(client, {
    type: "state",
    pet: client.pet,
    state: "running",
    title: target.newChat ? "Starting chat" : "Sending",
    body: truncate(text, 140),
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });

  submitTranscriptToResolvedTarget(client, target, text).catch(error => {
    errorBridge("transcript send failed", error);
    sendTranscriptSendFailure(client, error);
  });
}

async function submitTranscriptToResolvedTarget(client, target, text) {
  let threadId = target.threadId;
  if (target.newChat) {
    threadId = await startNewCodexThread(target.project);
    applyTranscriptTargetSelection(client, target.item, threadId);
    send(client, {
      type: "state",
      pet: client.pet,
      state: "running",
      title: "Sending",
      body: truncate(text, 140),
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
  } else {
    applyTranscriptTargetSelection(client, target.item, target.threadId);
  }

  await submitTranscriptToCodex(client, threadId, text);
}

async function startNewCodexThread(projectID) {
  const cwd = cwdFromProjectID(projectID);
  if (!cwd) {
    throw new Error("Pick a Codex project before starting a new chat.");
  }
  if (!fs.existsSync(cwd)) {
    throw new Error(`Project path does not exist: ${cwd}`);
  }

  maybeOpenCodex();
  const response = await getCodexAppServer().request("thread/start", {
    cwd
  }, { timeoutMs: 30000 });
  const threadId = stringOrNull(response?.thread?.id)
    || stringOrNull(response?.threadId)
    || stringOrNull(response?.id);
  if (!threadId) {
    throw new Error("Codex did not return a new chat ID.");
  }
  return threadId;
}

async function submitTranscriptToCodex(client, threadId, text) {
  maybeOpenCodex();
  const appServer = getCodexAppServer();
  const watcher = watchCodexTurn(client, threadId);

  try {
    const resume = await appServer.request("thread/resume", {
      threadId,
      excludeTurns: false,
      persistExtendedHistory: false
    }, { timeoutMs: 30000 });

    const activeTurn = activeTurnFromResume(resume);
    const input = [{
      type: "text",
      text,
      text_elements: []
    }];

    if (activeTurn) {
      await appServer.request("turn/steer", {
        threadId,
        input,
        expectedTurnId: activeTurn.id
      }, { timeoutMs: 30000 });
    } else {
      await appServer.request("turn/start", {
        threadId,
        input
      }, { timeoutMs: 30000 });
    }

    if (!watcher.isClosed()) {
      send(client, {
        type: "state",
        pet: client.pet,
        state: "thinking",
        title: "Codex is thinking",
        body: "Working on it",
        capabilities: client.capabilities,
        items: client.pickerItems,
        ...client.selection
      });
    }
  } catch (error) {
    watcher.stop();
    throw error;
  }
}

function watchCodexTurn(client, threadId) {
  const appServer = getCodexAppServer();
  let turnId = null;
  let responseText = "";
  let lastPreviewMs = 0;
  let isClosed = false;
  const sendTurnState = ({ state, title, body, text }) => {
    send(client, {
      type: "state",
      pet: client.pet,
      state,
      title,
      body,
      text,
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
  };

  const cleanupTimer = setTimeout(cleanup, 10 * 60 * 1000);
  cleanupTimer.unref();

  const unsubscribe = appServer.onNotification((method, params = {}) => {
    if (params.threadId !== threadId) {
      return;
    }

    if (method === "turn/started") {
      turnId = params.turn?.id || turnId;
      sendTurnState({
        state: "thinking",
        title: "Codex is thinking",
        body: "Working on it"
      });
      return;
    }

    const desktopState = method !== "item/agentMessage/delta" && method !== "turn/completed"
      ? codexDesktopStateFromNotification(method, params)
      : null;
    if (desktopState) {
      sendTurnState(desktopState);
      return;
    }

    if (method === "item/agentMessage/delta") {
      if (turnId && params.turnId && params.turnId !== turnId) {
        return;
      }
      if (typeof params.delta === "string") {
        responseText = appendAgentDelta(responseText, params.delta);
      }
      const now = Date.now();
      const trimmed = responseText.trim();
      if (trimmed && now - lastPreviewMs > 1500) {
        lastPreviewMs = now;
        sendTurnState({
          state: "running",
          title: "Codex is replying",
          body: truncate(trimmed, 180),
          text: trimmed
        });
      }
      return;
    }

    if (method === "turn/completed") {
      if (turnId && params.turn?.id && params.turn.id !== turnId) {
        return;
      }
      const status = params.turn?.status || "completed";
      if (status === "failed") {
        sendTurnState({
          state: "failed",
          title: "Codex failed",
          body: params.turn?.error?.message || "Open Codex for details"
        });
      } else {
        sendTurnState({
          state: "review",
          title: "Codex replied",
          body: truncate(responseText.trim() || "Open Codex to review", 240),
          text: responseText.trim()
        });
      }
      cleanup();
    }
  });

  function cleanup() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    clearTimeout(cleanupTimer);
    unsubscribe();
  }

  return {
    stop: cleanup,
    isClosed: () => isClosed
  };
}

function codexDesktopStateFromNotification(method, params = {}) {
  const source = params.state
    ?? params.threadRuntimeStatus
    ?? params.runtimeStatus
    ?? params.thread?.status
    ?? params.turn?.status
    ?? params.status;
  const mapped = codexDesktopStateFromStatus(source);
  if (!mapped) {
    return null;
  }

  if (mapped.kind === "approval") {
    return {
      state: "review",
      title: "Approval needed",
      body: params.message || params.body || "Codex is waiting for approval"
    };
  }
  if (mapped.kind === "user-input") {
    return {
      state: "review",
      title: "Input needed",
      body: params.message || params.body || "Codex is waiting for input"
    };
  }

  return {
    state: mapped.state,
    title: params.title || desktopStateTitle(mapped.state, method),
    body: params.body || params.message || desktopStateBody(mapped.state)
  };
}

function codexDesktopStateFromStatus(status) {
  if (!status) {
    return null;
  }

  if (typeof status === "object") {
    const flags = Array.isArray(status.activeFlags) ? status.activeFlags : [];
    if (flags.includes("waitingOnApproval")) {
      return { state: "review", kind: "approval" };
    }
    if (flags.includes("waitingOnUserInput")) {
      return { state: "review", kind: "user-input" };
    }
    return codexDesktopStateFromStatus(status.type || status.status || status.state);
  }

  switch (normalizeStatus(status)) {
    case "idle":
      return { state: "idle" };
    case "running":
    case "running-left":
    case "running-right":
    case "thinking":
    case "waiting":
    case "review":
    case "failed":
    case "waving":
    case "jumping":
      return { state: normalizeStatus(status) };
    case "active":
    case "inprogress":
    case "in-progress":
    case "loading":
    case "working":
      return { state: "running" };
    case "reasoning":
    case "thinking-started":
    case "thinking-start":
      return { state: "thinking" };
    case "needs-resume":
    case "resuming":
    case "pending":
    case "queued":
      return { state: "waiting" };
    case "approval":
    case "waitingonapproval":
    case "waiting-on-approval":
      return { state: "review", kind: "approval" };
    case "response":
    case "waitingonuserinput":
    case "waiting-on-user-input":
      return { state: "review", kind: "user-input" };
    case "complete":
    case "completed":
    case "done":
    case "success":
    case "succeeded":
      return { state: "review" };
    case "error":
    case "failure":
    case "systemerror":
    case "system-error":
    case "cancelled":
    case "canceled":
      return { state: "failed" };
    default:
      return null;
  }
}

function normalizeStatus(status) {
  return String(status || "")
    .trim()
    .replace(/_/g, "-")
    .toLowerCase();
}

function desktopStateTitle(state, method) {
  switch (state) {
    case "failed":
      return "Codex failed";
    case "review":
      return "Codex replied";
    case "thinking":
      return "Codex is thinking";
    case "waiting":
      return "Codex waiting";
    case "running-left":
    case "running-right":
    case "running":
      return "Codex is working";
    default:
      return method || "Codex";
  }
}

function desktopStateBody(state) {
  switch (state) {
    case "failed":
      return "Open Codex for details";
    case "review":
      return "Open Codex to review";
    case "thinking":
      return "Working on it";
    case "waiting":
      return "Waiting for Codex";
    case "running-left":
    case "running-right":
    case "running":
      return "Working on it";
    default:
      return "Bridge ready";
  }
}

function activeTurnFromResume(resume) {
  const turns = resume?.thread?.turns;
  if (!Array.isArray(turns)) {
    return null;
  }
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    if (turns[index]?.status === "inProgress") {
      return turns[index];
    }
  }
  return null;
}

async function handleChatOpened(client, message) {
  const target = resolveTranscriptTarget(client, message);
  if (!target?.threadId) {
    throw new Error("Pick a Codex chat before opening it.");
  }

  applyTranscriptTargetSelection(client, target.item, target.threadId);
  const localEntries = conversationEntriesForThread(target.threadId);
  let allEntries = localEntries.length >= 2 ? localEntries : [];
  let hasMore = allEntries.length > 20;
  let resume = null;
  let resumeError = null;
  if (allEntries.length === 0) {
    try {
      const appServer = getCodexAppServer();
      resume = await appServer.request("thread/resume", {
        threadId: target.threadId,
        excludeTurns: false,
        persistExtendedHistory: false
      }, { timeoutMs: 12000 });
      const page = await conversationPageFromAppServer(appServer, target.threadId, resume);
      allEntries = page.entries;
      hasMore = page.hasMore;
    } catch (error) {
      resumeError = error;
    }
  }
  if (allEntries.length === 0) {
    allEntries = localEntries;
    hasMore = localEntries.length > 20;
  }
  if (allEntries.length === 0 && resumeError) {
    throw resumeError;
  }

  const limit = 20;
  const item = target.item || client.pickerItems.find(candidate => candidate.chat === target.threadId);
  send(client, {
    type: "conversation",
    pet: client.pet,
    title: item?.title || "Conversation",
    entries: allEntries.slice(-limit),
    hasMore: hasMore || allEntries.length > limit,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

async function conversationPageFromAppServer(appServer, threadId, resume) {
  const itemsCursor = stringOrNull(resume?.itemsBackwardsCursor);
  if (!itemsCursor) {
    return {
      entries: conversationEntriesFromResume(resume),
      hasMore: Boolean(resume?.turnsBackwardsCursor)
    };
  }

  let cursor = itemsCursor;
  const descendingEntries = [];
  for (let pageIndex = 0; cursor && descendingEntries.length <= 20 && pageIndex < 5; pageIndex += 1) {
    const page = await appServer.request("thread/items/list", {
      threadId,
      cursor,
      limit: 100,
      sortDirection: "desc"
    }, { timeoutMs: 12000 });
    descendingEntries.push(...conversationEntriesFromItemPage(page));
    cursor = stringOrNull(page?.nextCursor);
  }
  return {
    entries: descendingEntries.reverse(),
    hasMore: Boolean(cursor) || descendingEntries.length > 20
  };
}

async function refreshClientStateFromCodex(client) {
  if (client.selection.newChat) {
    return;
  }

  const target = resolveTranscriptTarget(client, {
    project: client.selection.project,
    chat: client.selection.chat,
    target: client.selection.target,
    newChat: false
  });
  if (!target?.threadId) {
    return;
  }

  let resume = null;
  try {
    resume = await getCodexAppServer().request("thread/resume", {
      threadId: target.threadId,
      excludeTurns: false,
      persistExtendedHistory: false
    }, { timeoutMs: 12000 });
  } catch (error) {
    warnBridge("thread/resume state refresh failed", error);
  }

  const activeTurn = activeTurnFromResume(resume);
  if (activeTurn) {
    applyTranscriptTargetSelection(client, target.item, target.threadId);
    send(client, {
      type: "state",
      pet: client.pet,
      state: "thinking",
      title: "Codex is thinking",
      body: "Working on it",
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
    return;
  }

  const desktopState = codexDesktopStateFromNotification("thread/status/changed", {
    threadId: target.threadId,
    thread: resume?.thread,
    threadRuntimeStatus: resume?.thread?.status
  });
  if (desktopState && desktopState.state !== "idle" && desktopState.state !== "review") {
    applyTranscriptTargetSelection(client, target.item, target.threadId);
    send(client, {
      type: "state",
      pet: client.pet,
      ...desktopState,
      capabilities: client.capabilities,
      items: client.pickerItems,
      ...client.selection
    });
    return;
  }

  const replyText = latestAssistantTextFromResume(resume) || latestAssistantTextForThread(target.threadId);
  if (!replyText) {
    return;
  }

  applyTranscriptTargetSelection(client, target.item, target.threadId);
  const message = {
    type: "state",
    pet: client.pet,
    state: "review",
    title: "Codex replied",
    body: truncate(replyText, 240),
    text: replyText,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  };
  if (readStateSignaturesBySelection.get(selectionKey(message)) === durableStateSignature(message)) {
    return;
  }
  send(client, message);
}

function resolveTranscriptTarget(client, message) {
  if (!Array.isArray(client.pickerItems) || client.pickerItems.length === 0) {
    client.pickerItems = loadCodexPickerItems();
  }

  const explicitChat = stringOrNull(message.chat) || stringOrNull(client.selection.chat);
  const project = stringOrNull(message.project) || stringOrNull(client.selection.project);
  const wantsNewChat = message.newChat === true
    || client.selection.newChat === true
    || message.action === "new-chat"
    || isNewChatSelectionID(explicitChat);
  const chatItems = client.pickerItems.filter(item => stringOrNull(item.chat));
  if (wantsNewChat) {
    return {
      newChat: true,
      project,
      item: project
        ? client.pickerItems.find(item => item.kind === "project" && item.project === project) || null
        : null,
      threadId: null
    };
  }
  const exact = explicitChat
    ? chatItems.find(item => item.chat === explicitChat)
    : null;
  if (exact) {
    return { threadId: exact.chat, item: exact };
  }
  if (explicitChat && !isPlaceholderSelectionID(explicitChat, "chat")) {
    return { threadId: explicitChat, item: null };
  }

  const projectChat = project
    ? chatItems.find(item => item.project === project)
    : null;
  if (projectChat) {
    return { threadId: projectChat.chat, item: projectChat };
  }

  if (chatItems.length > 0) {
    return { threadId: chatItems[0].chat, item: chatItems[0] };
  }

  return null;
}

function applyTranscriptTargetSelection(client, item, threadId) {
  client.selection.target = "chat";
  client.selection.chat = threadId;
  client.selection.newChat = false;
  if (item?.project) {
    client.selection.project = item.project;
  }
  if (Number.isInteger(item?.projectIndex)) {
    client.selection.projectIndex = item.projectIndex;
  }
  if (Number.isInteger(item?.chatIndex)) {
    client.selection.chatIndex = item.chatIndex;
  }
}

function isPlaceholderSelectionID(value, prefix) {
  return new RegExp(`^${prefix}-\\d+$`).test(value);
}

function isNewChatSelectionID(value) {
  return typeof value === "string" && value.startsWith("new-chat:");
}

function latestAssistantTextFromResume(resume) {
  const turns = resume?.thread?.turns;
  if (!Array.isArray(turns)) {
    return "";
  }
  for (let turnIndex = turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const items = Array.isArray(turns[turnIndex]?.items) ? turns[turnIndex].items : [];
    for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
      const text = assistantTextFromObject(items[itemIndex]);
      if (text) {
        return text;
      }
    }
  }
  return "";
}

function conversationEntriesFromResume(resume) {
  const turns = resume?.thread?.turns;
  if (!Array.isArray(turns)) {
    return [];
  }
  const entries = [];
  turns.forEach((turn, turnIndex) => {
    const items = Array.isArray(turn?.items) ? turn.items : [];
    items.forEach((item, itemIndex) => {
      const entry = conversationEntryFromObject(item, {
        id: `resume-${turnIndex}-${itemIndex}`,
        turnId: stringOrNull(turn?.id)
      });
      if (entry) {
        entries.push(entry);
      }
    });
  });
  return entries;
}

function conversationEntriesFromItemPage(page) {
  const data = Array.isArray(page?.data) ? page.data : [];
  return data.flatMap((entry, index) => {
    const conversationEntry = conversationEntryFromObject(entry?.item, {
      id: `item-page-${index}`,
      turnId: stringOrNull(entry?.turnId)
    });
    return conversationEntry ? [conversationEntry] : [];
  });
}

function conversationEntriesForThread(threadId) {
  const file = sessionFileForThread(threadId);
  if (!file) {
    return [];
  }

  const responseEntries = [];
  const legacyEntries = [];
  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
  lines.forEach((line, index) => {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      return;
    }
    const entry = conversationEntryFromObject(event.payload, {
      id: `session-${index}`,
      turnId: stringOrNull(event.payload?.turn_id) || stringOrNull(event.payload?.turnId)
    });
    if (!entry) {
      return;
    }
    if (event.type === "response_item") {
      responseEntries.push(entry);
    } else if (event.type === "event_msg" || event.type === "message") {
      legacyEntries.push(entry);
    }
  });
  return responseEntries.length > 0 ? responseEntries : legacyEntries;
}

function conversationEntryFromObject(value, fallback) {
  if (!value || typeof value !== "object") {
    return null;
  }
  const type = typeof value.type === "string" ? value.type : "";
  const role = value.role === "user" || type === "userMessage" || type === "user_message"
    ? "user"
    : value.role === "assistant" || type === "agentMessage" || type === "agent_message"
      ? "assistant"
      : null;
  if (!role) {
    return null;
  }

  const rawText = textFromConversationObject(value);
  const text = role === "user" ? cleanConversationText(rawText) : rawText.trim();
  if (!text) {
    return null;
  }
  return {
    id: stringOrNull(value.id) || fallback.id,
    turnId: stringOrNull(value.turnId) || stringOrNull(value.turn_id) || fallback.turnId,
    role,
    text,
    phase: stringOrNull(value.phase)
  };
}

function textFromConversationObject(value) {
  if (typeof value.message === "string") {
    return value.message;
  }
  if (typeof value.text === "string") {
    return value.text;
  }
  if (Array.isArray(value.content)) {
    return value.content
      .map(part => typeof part?.text === "string" ? part.text : "")
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

function cleanConversationText(text) {
  const withoutBlocks = String(text || "")
    .replace(/<environment_context>[\s\S]*?<\/environment_context>/g, "")
    .replace(/<permissions instructions>[\s\S]*?<\/permissions instructions>/g, "")
    .replace(/<apps_instructions>[\s\S]*?<\/apps_instructions>/g, "")
    .replace(/<skills_instructions>[\s\S]*?<\/skills_instructions>/g, "")
    .replace(/<plugins_instructions>[\s\S]*?<\/plugins_instructions>/g, "")
    .replace(/<recommended_plugins>[\s\S]*?<\/recommended_plugins>/g, "")
    .replace(/<response-annotations>[\s\S]*?<\/response-annotations>/g, "")
    .replace(/<INSTRUCTIONS>[\s\S]*?<\/INSTRUCTIONS>/g, "");
  return withoutBlocks.split("# AGENTS.md instructions")[0].trim();
}

function latestAssistantTextForThread(threadId) {
  const file = sessionFileForThread(threadId);
  if (!file) {
    return "";
  }

  let finalAnswer = "";
  let latestAgentMessage = "";
  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
  for (const line of lines) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }

    const responseText = assistantTextFromObject(event.payload);
    if (responseText) {
      if (event.payload?.phase === "final_answer") {
        finalAnswer = responseText;
      }
      latestAgentMessage = responseText;
    }
    if (event.payload?.type === "agent_message" && typeof event.payload.message === "string") {
      if (event.payload.phase === "final_answer") {
        finalAnswer = event.payload.message.trim();
      }
      latestAgentMessage = event.payload.message.trim();
    }
  }

  return finalAnswer || latestAgentMessage;
}

function assistantTextFromObject(value) {
  if (!value || typeof value !== "object") {
    return "";
  }
  if (value.role === "assistant" && typeof value.message === "string") {
    return value.message.trim();
  }
  if (value.role === "assistant" && typeof value.text === "string") {
    return value.text.trim();
  }
  if (value.type === "agentMessage" && typeof value.text === "string") {
    return value.text.trim();
  }
  if (value.role === "assistant" && Array.isArray(value.content)) {
    return value.content
      .map(part => typeof part?.text === "string" ? part.text : "")
      .filter(Boolean)
      .join("\n")
      .trim();
  }
  if ((value.type === "agent_message" || value.type === "message")
    && typeof value.message === "string"
    && value.role !== "user") {
    return value.message.trim();
  }
  return "";
}

function sessionFileForThread(threadId) {
  if (!threadId) {
    return null;
  }
  const knownFile = sessionFileByThread.get(threadId);
  if (knownFile && fs.existsSync(knownFile)) {
    return knownFile;
  }
  const files = findSessionFiles(currentCodexSessionsDir());
  for (const file of files) {
    const lines = fs.readFileSync(file, "utf8").split("\n").slice(0, 20);
    for (const line of lines) {
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        continue;
      }
      if (event.type === "session_meta" && event.payload?.id === threadId) {
        return file;
      }
    }
  }
  return null;
}

function cwdFromProjectID(projectID) {
  if (typeof projectID !== "string" || !projectID.startsWith("project:")) {
    return null;
  }
  const cwd = projectID.slice("project:".length);
  return path.isAbsolute(cwd) ? cwd : null;
}

function sendTranscriptSendFailure(client, error) {
  send(client, {
    type: "state",
    pet: client.pet,
    state: "failed",
    title: "Send failed",
    body: error.message,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

async function transcribeAudio(wavPath) {
  const provider = currentTranscriptionProvider();
  if (provider === "mock") {
    return process.env.CODEX_WATCH_MOCK_TRANSCRIPT || "Mock transcript from watch audio.";
  }

  const errors = [];
  if (provider !== "openai") {
    try {
      return await transcribeWithCodexDesktop(wavPath);
    } catch (error) {
      errors.push(`Codex desktop transcription failed: ${error.message}`);
      if (provider !== "auto") {
        throw new Error(errors[0]);
      }
    }
  }

  if (process.env.OPENAI_API_KEY) {
    try {
      return await transcribeWithOpenAI(wavPath);
    } catch (error) {
      errors.push(`OpenAI transcription failed: ${error.message}`);
    }
  } else if (provider === "openai") {
    errors.push("OPENAI_API_KEY is not set.");
  }

  throw new Error(errors.join(" "));
}

async function transcribeWithCodexDesktop(wavPath) {
  const audio = await fs.promises.readFile(wavPath);
  const { body, boundary } = createMultipartBody({
    file: {
      name: "file",
      filename: path.basename(wavPath),
      contentType: "audio/wav",
      data: audio
    }
  });

  return transcribeWithCodexDesktopBody(body, boundary, { refreshToken: false });
}

async function transcribeWithCodexDesktopBody(body, boundary, { refreshToken }) {
  const token = await getCodexAppServer().getAuthToken({ refreshToken });
  if (!token) {
    throw new Error("Codex is not signed in with ChatGPT auth.");
  }

  const headers = codexDesktopHeaders(token, {
    "content-type": `multipart/form-data; boundary=${boundary}`
  });
  const response = await fetch(`${codexAPIBaseURL}/transcribe`, {
    method: "POST",
    headers,
    body
  });
  if (response.status === 401 && !refreshToken) {
    return transcribeWithCodexDesktopBody(body, boundary, { refreshToken: true });
  }

  const text = await response.text();
  let payload = {};
  try {
    payload = JSON.parse(text);
  } catch {}
  if (!response.ok) {
    throw new Error(errorMessageFromCodexResponse(response, payload, text));
  }
  return typeof payload.text === "string" ? payload.text : "";
}

async function transcribeWithOpenAI(wavPath) {
  const audio = await fs.promises.readFile(wavPath);
  const form = new FormData();
  form.append("model", process.env.CODEX_WATCH_TRANSCRIBE_MODEL || defaultTranscriptionModel);
  form.append("file", new Blob([audio], { type: "audio/wav" }), path.basename(wavPath));

  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${process.env.OPENAI_API_KEY}`
    },
    body: form
  });
  const body = await response.text();
  let payload = {};
  try {
    payload = JSON.parse(body);
  } catch {}
  if (!response.ok) {
    throw new Error(payload.error?.message || body || `Transcription failed with ${response.status}`);
  }
  return typeof payload.text === "string" ? payload.text : "";
}

function getCodexAppServer() {
  if (process.env.CODEX_WATCH_MOCK_APP_SERVER === "1") {
    codexAppServer ??= new MockCodexAppServerClient();
    return codexAppServer;
  }

  codexAppServer ??= new CodexAppServerClient();
  return codexAppServer;
}

class MockCodexAppServerClient {
  notificationHandlers = new Set();

  async getAuthToken() {
    return "mock-token";
  }

  async request(method, params = {}) {
    switch (method) {
      case "thread/resume":
        if (process.env.CODEX_WATCH_MOCK_RESUME_ERROR === "1") {
          throw new Error("Mock thread/resume unavailable");
        }
        if (process.env.CODEX_WATCH_MOCK_RESUME_HISTORY) {
          return JSON.parse(process.env.CODEX_WATCH_MOCK_RESUME_HISTORY);
        }
        if (process.env.CODEX_WATCH_MOCK_RESUME_STATE === "thinking") {
          return {
            thread: {
              id: params.threadId,
              status: { type: "active" },
              turns: [{ id: "mock-active-turn", status: "inProgress", items: [] }]
            }
          };
        }
        if (process.env.CODEX_WATCH_MOCK_RESUME_REPLY) {
          return {
            thread: {
              id: params.threadId,
              status: { type: "idle" },
              turns: [{
                id: "mock-completed-turn",
                status: "completed",
                items: [{
                  type: "message",
                  role: "assistant",
                  content: [{ type: "output_text", text: process.env.CODEX_WATCH_MOCK_RESUME_REPLY }]
                }]
              }]
            }
          };
        }
        return {
          thread: {
            id: params.threadId,
            status: { type: "idle" },
            turns: []
          }
          };
      case "thread/items/list":
        if (process.env.CODEX_WATCH_MOCK_ITEMS_LIST) {
          return JSON.parse(process.env.CODEX_WATCH_MOCK_ITEMS_LIST);
        }
        return { data: [], nextCursor: null, backwardsCursor: null };
      case "thread/start": {
        const threadId = `mock-new-thread-${Date.now()}`;
        queueMicrotask(() => {
          this.emitNotification("thread/started", {
            thread: { id: threadId, cwd: params.cwd, status: { type: "idle" } }
          });
        });
        return {
          thread: {
            id: threadId,
            cwd: params.cwd,
            status: { type: "idle" }
          }
        };
      }
      case "turn/start":
      case "turn/steer": {
        const turnId = `mock-turn-${Date.now()}`;
        const threadId = params.threadId;
        queueMicrotask(() => {
          this.emitNotification("turn/started", {
            threadId,
            turn: { id: turnId, status: "inProgress", items: [] }
          });
          const activeFlag = process.env.CODEX_WATCH_MOCK_ACTIVE_FLAG;
          if (activeFlag) {
            this.emitNotification("thread/status", {
              threadId,
              threadRuntimeStatus: {
                type: "active",
                activeFlags: [activeFlag]
              }
            });
          }
          for (const delta of mockReplyDeltas()) {
            this.emitNotification("item/agentMessage/delta", {
              threadId,
              turnId,
              itemId: "mock-agent-message",
              delta
            });
          }
          this.emitNotification("turn/completed", {
            threadId,
            turn: { id: turnId, status: "completed", items: [] }
          });
        });
        return {};
      }
      default:
        return {};
    }
  }

  onNotification(handler) {
    this.notificationHandlers.add(handler);
    return () => {
      this.notificationHandlers.delete(handler);
    };
  }

  emitNotification(method, params) {
    for (const handler of this.notificationHandlers) {
      handler(method, params);
    }
  }
}

function appendAgentDelta(current, delta) {
  if (!delta) {
    return current;
  }
  if (!current) {
    return delta;
  }
  if (shouldInsertBoundarySpace(current, delta)) {
    return `${current} ${delta}`;
  }
  return current + delta;
}

function shouldInsertBoundarySpace(current, delta) {
  const last = current[current.length - 1];
  const first = delta[0];
  if (!last || !first || /\s/.test(last) || /\s/.test(first)) {
    return false;
  }
  return /[.!?]/.test(last) && /[A-Z"`'“‘(\[]/.test(first);
}

function mockReplyDeltas() {
  const rawChunks = process.env.CODEX_WATCH_MOCK_REPLY_CHUNKS;
  if (rawChunks) {
    try {
      const chunks = JSON.parse(rawChunks);
      if (Array.isArray(chunks)) {
        return chunks.map(String);
      }
    } catch {
      return rawChunks.split("|");
    }
  }
  return [process.env.CODEX_WATCH_MOCK_REPLY || "Mock **reply** with `inlineCode`."];
}

class CodexAppServerClient {
  proc = null;
  readyPromise = null;
  stdoutBuffer = "";
  nextRequestID = 1;
  pending = new Map();
  notificationHandlers = new Set();

  async getAuthToken({ refreshToken }) {
    const status = await this.request("getAuthStatus", {
      includeToken: true,
      refreshToken
    });
    return typeof status?.authToken === "string" && status.authToken.length > 0
      ? status.authToken
      : null;
  }

  async request(method, params = {}, { timeoutMs = 20000 } = {}) {
    await this.ensureReady();
    return this.sendRequest(method, params, { timeoutMs });
  }

  onNotification(handler) {
    this.notificationHandlers.add(handler);
    return () => {
      this.notificationHandlers.delete(handler);
    };
  }

  async ensureReady() {
    if (this.proc && this.readyPromise) {
      return this.readyPromise;
    }
    this.startProcess();
    this.readyPromise = this.sendRequest("initialize", {
      clientInfo: {
        name: "codex-watch-bridge",
        title: "Codex Watch Bridge",
        version: "0.1.0"
      },
      capabilities: {
        experimentalApi: true,
        requestAttestation: false
      }
    }, { timeoutMs: 20000 }).catch(error => {
      this.dispose();
      throw error;
    });
    return this.readyPromise;
  }

  startProcess() {
    const executable = resolveCodexCLIPath();
    if (!executable) {
      throw new Error("Unable to locate the Codex CLI/app-server binary.");
    }

    this.proc = spawn(executable, ["app-server", "--listen", "stdio://"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        LOG_FORMAT: "json",
        RUST_LOG: process.env.RUST_LOG || "warn",
        CODEX_INTERNAL_ORIGINATOR_OVERRIDE: "Codex Watch Bridge"
      }
    });
    this.stdoutBuffer = "";
    this.proc.stdout.on("data", chunk => this.handleStdout(chunk));
    this.proc.stderr.on("data", chunk => this.handleStderr(chunk));
    this.proc.on("exit", (code, signal) => {
      const reason = signal ? `signal ${signal}` : `exit code ${code}`;
      this.rejectPending(new Error(`Codex app-server exited with ${reason}.`));
      this.proc = null;
      this.readyPromise = null;
    });
    this.proc.on("error", error => {
      this.rejectPending(error);
      this.proc = null;
      this.readyPromise = null;
    });
  }

  sendRequest(method, params, { timeoutMs }) {
    if (!this.proc?.stdin || this.proc.stdin.destroyed) {
      throw new Error("Codex app-server is not running.");
    }

    const id = this.nextRequestID++;
    const message = { id, method, params };
    this.proc.stdin.write(`${JSON.stringify(message)}\n`);
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for Codex app-server ${method}.`));
      }, timeoutMs);
      timeout.unref();
      this.pending.set(id, { resolve, reject, timeout });
    });
  }

  handleStdout(chunk) {
    this.stdoutBuffer += chunk.toString("utf8");
    let newlineIndex;
    while ((newlineIndex = this.stdoutBuffer.indexOf("\n")) >= 0) {
      const line = this.stdoutBuffer.slice(0, newlineIndex).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newlineIndex + 1);
      if (line.length > 0) {
        this.handleMessageLine(line);
      }
    }
  }

  handleMessageLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      warnBridge("codex app-server emitted non-json output", new Error(line.slice(0, 160)));
      return;
    }

    if ("id" in message && ("result" in message || "error" in message)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timeout);
      if (message.error) {
        pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (typeof message.method === "string" && !("id" in message)) {
      this.emitNotification(message.method, message.params || {});
      return;
    }

    if ("id" in message && typeof message.method === "string") {
      this.respondToServerRequest(message.id, {
        code: -32601,
        message: `Unsupported server request: ${message.method}`
      });
    }
  }

  emitNotification(method, params) {
    for (const handler of this.notificationHandlers) {
      try {
        handler(method, params);
      } catch (error) {
        warnBridge("codex app-server notification handler failed", error);
      }
    }
  }

  respondToServerRequest(id, error) {
    try {
      this.proc?.stdin?.write(`${JSON.stringify({ id, error })}\n`);
    } catch {}
  }

  handleStderr(chunk) {
    for (const line of chunk.toString("utf8").split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const payload = JSON.parse(trimmed);
        const level = String(payload.level || "").toUpperCase();
        if (level === "ERROR") {
          errorBridge("codex app-server error", new Error(payload.fields?.message || trimmed));
        }
      } catch {
        warnBridge("codex app-server warning", new Error(trimmed));
      }
    }
  }

  rejectPending(error) {
    for (const { reject, timeout } of this.pending.values()) {
      clearTimeout(timeout);
      reject(error);
    }
    this.pending.clear();
  }

  dispose() {
    if (this.proc && !this.proc.killed) {
      this.proc.kill();
    }
    this.rejectPending(new Error("Codex app-server connection disposed."));
    this.proc = null;
    this.readyPromise = null;
    this.stdoutBuffer = "";
  }
}

function resolveCodexCLIPath() {
  const candidates = [
    process.env.CODEX_CLI_PATH,
    "/Applications/Codex.app/Contents/Resources/codex",
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex"
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  try {
    const found = execFileSync("which", ["codex"], { encoding: "utf8" }).trim();
    return found.length > 0 ? found : null;
  } catch {
    return null;
  }
}

function createMultipartBody({ file, fields = {} }) {
  const boundary = `----codex-watch-${crypto.randomUUID()}`;
  const chunks = [];
  for (const [name, value] of Object.entries(fields)) {
    chunks.push(Buffer.from(`--${boundary}\r\n`));
    chunks.push(Buffer.from(`Content-Disposition: form-data; name="${escapeMultipartValue(name)}"\r\n\r\n`));
    chunks.push(Buffer.from(String(value)));
    chunks.push(Buffer.from("\r\n"));
  }
  chunks.push(Buffer.from(`--${boundary}\r\n`));
  chunks.push(Buffer.from(
    `Content-Disposition: form-data; name="${escapeMultipartValue(file.name)}"; filename="${escapeMultipartValue(file.filename)}"\r\n`
  ));
  chunks.push(Buffer.from(`Content-Type: ${file.contentType}\r\n\r\n`));
  chunks.push(file.data);
  chunks.push(Buffer.from(`\r\n--${boundary}--\r\n`));
  return { body: Buffer.concat(chunks), boundary };
}

function escapeMultipartValue(value) {
  return String(value).replaceAll('"', "");
}

function codexDesktopHeaders(token, headers = {}) {
  const merged = {
    ...headers,
    authorization: `Bearer ${token}`,
    originator: "Codex Desktop",
    "user-agent": codexDesktopUserAgent()
  };
  const accountID = chatGPTAccountIDFromToken(token);
  if (accountID) {
    merged["chatgpt-account-id"] = accountID;
  }
  return merged;
}

let codexDesktopVersionCache = null;
function codexDesktopUserAgent() {
  codexDesktopVersionCache ??= readCodexDesktopVersion();
  const platform = process.platform === "darwin"
    ? "Macintosh; Intel Mac OS X"
    : process.platform;
  return `Codex Desktop/${codexDesktopVersionCache} (${platform}; ${process.arch})`;
}

function readCodexDesktopVersion() {
  try {
    return execFileSync("defaults", [
      "read",
      "/Applications/Codex.app/Contents/Info",
      "CFBundleShortVersionString"
    ], { encoding: "utf8" }).trim();
  } catch {
    return "unknown";
  }
}

function chatGPTAccountIDFromToken(token) {
  const payload = token.split(".")[1];
  if (!payload) return null;
  try {
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    const auth = parsed["https://api.openai.com/auth"];
    return typeof auth?.chatgpt_account_id === "string"
      ? auth.chatgpt_account_id
      : null;
  } catch {
    return null;
  }
}

function errorMessageFromCodexResponse(response, payload, body) {
  if (typeof payload.detail === "string") {
    return payload.detail;
  }
  if (typeof payload.error === "string") {
    return payload.error;
  }
  if (typeof payload.error?.message === "string") {
    return payload.error.message;
  }
  return body || `Codex transcription failed with ${response.status}`;
}

function sendTranscriptionFailure(client, error) {
  send(client, {
    type: "state",
    pet: client.pet,
    state: "failed",
    title: "Transcription unavailable",
    body: error.message,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  });
}

function writePCMFloat32Wav(rawPath, wavPath, { sampleRate, channels }) {
  const raw = fs.readFileSync(rawPath);
  const samples = Math.floor(raw.length / 4);
  const pcm = Buffer.alloc(samples * 2);

  for (let index = 0; index < samples; index += 1) {
    const sample = Math.max(-1, Math.min(1, raw.readFloatLE(index * 4)));
    const value = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
    pcm.writeInt16LE(Math.round(value), index * 2);
  }

  const header = Buffer.alloc(44);
  const byteRate = sampleRate * channels * 2;
  const blockAlign = channels * 2;
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);

  fs.writeFileSync(wavPath, Buffer.concat([header, pcm]));
}

function handleSelection(client, message) {
  updateClientSelection(client, message);
  logVerbose(
    message.type,
    client.selection.target,
    `project=${redactedSelectionID(client.selection.project)}`,
    `chat=${redactedSelectionID(client.selection.chat)}`,
    client.selection.newChat ? "new-chat" : "existing-chat",
    typeof message.delta === "number" ? `delta=${message.delta}` : "focus"
  );
  broadcast({
    type: "selection",
    pet: client.pet,
    state: message.state || "idle",
    body: "Digital Crown",
    capabilities: client.capabilities,
    items: client.pickerItems,
    action: message.action || null,
    delta: Number.isFinite(message.delta) ? message.delta : null,
    index: Number.isFinite(message.index) ? message.index : null,
    ...client.selection
  });
}

function resolveClientSelection(client) {
  const chats = client.pickerItems.filter(item => stringOrNull(item.chat));
  const exact = chats.find(item => item.chat === client.selection.chat);
  const indexed = chats.find(item => {
    return item.projectIndex === client.selection.projectIndex
      && item.chatIndex === client.selection.chatIndex;
  });
  const selected = exact || indexed || chats[0];
  if (selected) {
    applyTranscriptTargetSelection(client, selected, selected.chat);
    return;
  }

  const projects = client.pickerItems.filter(item => item.kind === "project" && stringOrNull(item.project));
  const project = projects.find(item => item.project === client.selection.project)
    || projects.find(item => item.projectIndex === client.selection.projectIndex)
    || projects[0];
  if (project) {
    client.selection.target = "project";
    client.selection.project = project.project;
    client.selection.projectIndex = project.projectIndex ?? 0;
    client.selection.chat = "";
    client.selection.chatIndex = 0;
    client.selection.newChat = false;
  }
}

function updateClientPickerItems(client, message) {
  if (Array.isArray(message.items)) {
    client.pickerItems = normalizePickerItems(message.items);
  }
}

function normalizePickerItems(items) {
  return items
    .filter(item => item && typeof item === "object")
    .map((item, index) => {
      const project = stringOrNull(item.project);
      const chat = stringOrNull(item.chat);
      const id = stringOrNull(item.id) || chat || project || `picker-item-${index}`;
      return {
        id,
        title: stringOrNull(item.title) || id,
        subtitle: stringOrNull(item.subtitle),
        kind: stringOrNull(item.kind),
        section: stringOrNull(item.section),
        project,
        chat,
        projectIndex: integerOrNull(item.projectIndex),
        chatIndex: integerOrNull(item.chatIndex),
        unread: typeof item.unread === "boolean" ? item.unread : null,
        pinned: typeof item.pinned === "boolean" ? item.pinned : null
      };
    });
}

function loadCodexPickerItems() {
  try {
    const sessionFiles = findSessionFiles(currentCodexSessionsDir())
      .map(file => ({ file, mtimeMs: fs.statSync(file).mtimeMs }))
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .slice(0, Number(process.env.CODEX_WATCH_MAX_SESSIONS || 500));
    const sessions = sessionFiles
      .map(({ file, mtimeMs }) => readSessionSummary(file, mtimeMs))
      .filter(Boolean);
    sessionFileByThread.clear();
    for (const session of sessions) {
      sessionFileByThread.set(session.id, session.file);
    }
    return buildPickerItems(sessions);
  } catch (error) {
    warnBridge("failed to load Codex sessions", error);
    return fallbackPickerItems();
  }
}

function currentCodexSessionsDir() {
  return process.env.CODEX_SESSIONS_DIR || defaultCodexSessionsDir;
}

function currentTranscriptionProvider() {
  return process.env.CODEX_WATCH_TRANSCRIBE_PROVIDER || "auto";
}

function findSessionFiles(directory) {
  if (!fs.existsSync(directory)) {
    return [];
  }
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...findSessionFiles(entryPath));
    } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      files.push(entryPath);
    }
  }
  return files;
}

function readSessionSummary(file, mtimeMs) {
  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
  let meta = null;
  const userTexts = [];
  for (const line of lines) {
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.type === "session_meta") {
      meta = event.payload;
      continue;
    }
    const text = userTextFromEvent(event);
    if (text) {
      userTexts.push(text);
    }
  }
  if (!meta?.id || !meta?.cwd) {
    return null;
  }
  return {
    id: meta.id,
    cwd: meta.cwd,
    timestamp: meta.timestamp || new Date(mtimeMs).toISOString(),
    title: summarizePrompt(userTexts) || shortSessionID(meta.id),
    source: meta.source || null,
    file,
    mtimeMs
  };
}

function userTextFromEvent(event) {
  const payload = event.payload || {};
  if (payload.role !== "user" && payload.type !== "user_message") {
    return null;
  }
  if (typeof payload.message === "string") {
    return cleanPromptText(payload.message);
  }
  if (Array.isArray(payload.content)) {
    const text = payload.content
      .map(part => typeof part?.text === "string" ? part.text : "")
      .filter(Boolean)
      .join("\n");
    return cleanPromptText(text);
  }
  return null;
}

function cleanPromptText(text) {
  const withoutContext = text
    .replace(/<environment_context>[\s\S]*?<\/environment_context>/g, "")
    .replace(/<permissions instructions>[\s\S]*?<\/permissions instructions>/g, "")
    .replace(/<apps_instructions>[\s\S]*?<\/apps_instructions>/g, "")
    .replace(/<skills_instructions>[\s\S]*?<\/skills_instructions>/g, "")
    .replace(/<plugins_instructions>[\s\S]*?<\/plugins_instructions>/g, "");
  const lines = withoutContext
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .filter(line => !line.startsWith("# AGENTS.md instructions"))
    .filter(line => !line.startsWith("<INSTRUCTIONS>"))
    .filter(line => !line.startsWith("</INSTRUCTIONS>"));
  const natural = lines.find(line => !line.startsWith("/") && !line.startsWith("<"));
  return natural || lines[0] || "";
}

function summarizePrompt(texts) {
  for (let index = texts.length - 1; index >= 0; index -= 1) {
    const text = texts[index]
      .replace(/\s+/g, " ")
      .trim();
    if (text.length > 0) {
      return truncate(text, 56);
    }
  }
  return "";
}

function buildPickerItems(sessions) {
  const projectMap = new Map();
  for (const session of sessions) {
    const projectID = projectIDForPath(session.cwd);
    if (!projectMap.has(projectID)) {
      projectMap.set(projectID, {
        id: projectID,
        cwd: session.cwd,
        latestMs: session.mtimeMs,
        sessions: []
      });
    }
    const project = projectMap.get(projectID);
    project.latestMs = Math.max(project.latestMs, session.mtimeMs);
    project.sessions.push(session);
  }

  const projects = [...projectMap.values()]
    .sort((left, right) => right.latestMs - left.latestMs)
    .slice(0, Number(process.env.CODEX_WATCH_MAX_PROJECTS || 80));
  const items = [];
  projects.forEach((project, projectIndex) => {
    const sortedSessions = project.sessions
      .sort((left, right) => right.mtimeMs - left.mtimeMs)
      .slice(0, Number(process.env.CODEX_WATCH_MAX_CHATS_PER_PROJECT || 80));
    items.push({
      id: project.id,
      title: projectTitle(project.cwd),
      subtitle: compactPath(project.cwd),
      kind: "project",
      section: "projects",
      project: project.id,
      projectIndex
    });
    sortedSessions.forEach((session, chatIndex) => {
      items.push({
        id: session.id,
        title: session.title,
        subtitle: relativeTimeLabel(session.mtimeMs),
        kind: "chat",
        section: "chats",
        project: project.id,
        chat: session.id,
        projectIndex,
        chatIndex
      });
    });
  });

  return items.length > 0 ? items : fallbackPickerItems();
}

function fallbackPickerItems() {
  const cwd = process.cwd();
  const project = projectIDForPath(cwd);
  return [
    {
      id: project,
      title: projectTitle(cwd),
      subtitle: compactPath(cwd),
      kind: "project",
      section: "projects",
      project,
      projectIndex: 0
    }
  ];
}

function projectIDForPath(value) {
  return `project:${value}`;
}

function projectTitle(value) {
  return path.basename(value) || value;
}

function compactPath(value) {
  const home = os.homedir();
  if (value === home) {
    return "~";
  }
  if (value.startsWith(`${home}${path.sep}`)) {
    return `~/${value.slice(home.length + 1)}`;
  }
  return value;
}

function shortSessionID(value) {
  return value.split("-").at(-1) || value;
}

function truncate(value, maxLength) {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 3)}...`;
}

function relativeTimeLabel(mtimeMs) {
  const deltaSeconds = Math.max(0, Math.round((Date.now() - mtimeMs) / 1000));
  if (deltaSeconds < 60) {
    return "Just now";
  }
  const deltaMinutes = Math.round(deltaSeconds / 60);
  if (deltaMinutes < 60) {
    return `${deltaMinutes}m ago`;
  }
  const deltaHours = Math.round(deltaMinutes / 60);
  if (deltaHours < 24) {
    return `${deltaHours}h ago`;
  }
  const deltaDays = Math.round(deltaHours / 24);
  if (deltaDays < 14) {
    return `${deltaDays}d ago`;
  }
  return new Date(mtimeMs).toLocaleDateString();
}

function stringOrNull(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function integerOrNull(value) {
  return Number.isInteger(value) ? value : null;
}

function updateClientSelection(client, message) {
  if (typeof message.target === "string" && ["project", "chat"].includes(message.target)) {
    client.selection.target = message.target;
  }
  if (typeof message.project === "string" && message.project.length > 0) {
    client.selection.project = message.project;
  }
  if (typeof message.chat === "string" && message.chat.length > 0) {
    client.selection.chat = message.chat;
  }
  if (message.newChat === true || message.action === "new-chat" || isNewChatSelectionID(message.chat)) {
    client.selection.newChat = true;
  } else if (message.newChat === false || (typeof message.chat === "string" && !isNewChatSelectionID(message.chat))) {
    client.selection.newChat = false;
  }
  if (Number.isInteger(message.projectIndex)) {
    client.selection.projectIndex = message.projectIndex;
  }
  if (Number.isInteger(message.chatIndex)) {
    client.selection.chatIndex = message.chatIndex;
  }
}

function rememberDurableState(message) {
  if (!message || message.type !== "state") {
    return;
  }
  const state = normalizeStatus(message.state);
  if (!isDurableWatchState(state)) {
    return;
  }

  const durableState = {
    ...message,
    state,
    capabilities: undefined,
    items: undefined
  };
  const key = selectionKey(durableState);
  const signature = durableStateSignature(durableState);
  if (readStateSignaturesBySelection.get(key) === signature) {
    return;
  }
  durableStateBySelection.set(key, durableState);
  readStateSignaturesBySelection.delete(key);
  latestDurableState = durableState;
}

function replayStateForClient(client) {
  const durableState = durableStateBySelection.get(selectionKey(client.selection)) || latestDurableState;
  if (!durableState) {
    return null;
  }
  return {
    ...durableState,
    pet: client.pet,
    capabilities: client.capabilities,
    items: client.pickerItems,
    ...client.selection
  };
}

function clearDurableStateForClient(client) {
  const key = selectionKey(client.selection);
  const existing = durableStateBySelection.get(key);
  const signature = existing ? durableStateSignature(existing) : null;
  durableStateBySelection.delete(key);
  if (signature) {
    readStateSignaturesBySelection.set(key, signature);
  }
  if (latestDurableState && selectionKey(latestDurableState) === key && existing === latestDurableState) {
    latestDurableState = Array.from(durableStateBySelection.values()).at(-1) || null;
  }
}

function isDurableWatchState(state) {
  return [
    "review",
    "thinking",
    "running",
    "running-left",
    "running-right"
  ].includes(state);
}

function selectionKey(value = {}) {
  return [
    value.project || "",
    value.chat || "",
    Number.isInteger(value.projectIndex) ? value.projectIndex : "",
    Number.isInteger(value.chatIndex) ? value.chatIndex : "",
    value.newChat === true ? "new" : "existing"
  ].join("\u001f");
}

function durableStateSignature(value = {}) {
  return [
    normalizeStatus(value.state),
    value.title || "",
    value.body || "",
    value.text || ""
  ].join("\u001f");
}

function send(client, message) {
  rememberDurableState(message);
  if (Array.isArray(client.queue)) {
    client.queue.push(message);
    return;
  }
  if (client.socket.destroyed) return;
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  const header = frameHeader(payload.length);
  client.socket.write(Buffer.concat([header, payload]));
}

function broadcast(message) {
  for (const client of clients) {
    send(client, { ...message, pet: client.pet, ...client.selection });
  }
}

function getHTTPClient(id, socket) {
  const existing = httpClients.get(id);
  if (existing) {
    return existing;
  }

  const client = {
    id,
    queue: [],
    audioStream: null,
    audioPath: null,
    audioBytes: 0,
    audioSampleRate: 48000,
    audioChannels: 1,
    pet: "codex",
    capabilities: [],
    selection: {
      target: "chat",
      project: "project-1",
      chat: "chat-1",
      projectIndex: 0,
      chatIndex: 0,
      newChat: false
    },
    pickerItems: loadCodexPickerItems()
  };
  httpClients.set(id, client);
  clients.add(client);
  logConnection("watch http connected", socket);
  return client;
}

function clientIDFromURL(requestURL) {
  const id = requestURL.searchParams.get("client");
  if (id && /^[A-Za-z0-9._:-]{1,80}$/.test(id)) {
    return id;
  }
  return "watch-http-default";
}

function isAuthorizedRequest(request, expectedToken) {
  if (!expectedToken) {
    return true;
  }
  const header = request.headers.authorization;
  const match = typeof header === "string" ? /^Bearer\s+(.+)$/i.exec(header) : null;
  const candidate = match?.[1]?.trim() || "";
  const expectedDigest = crypto.createHash("sha256").update(expectedToken).digest();
  const candidateDigest = crypto.createHash("sha256").update(candidate).digest();
  return crypto.timingSafeEqual(expectedDigest, candidateDigest);
}

function unauthorizedJSONResponse(response) {
  response.writeHead(401, {
    "content-type": "application/json",
    "www-authenticate": 'Bearer realm="codex-watch"'
  });
  response.end(JSON.stringify({ ok: false, error: "Unauthorized" }));
}

function drainQueuedMessages(client) {
  if (!Array.isArray(client.queue)) {
    return [];
  }
  return client.queue.splice(0, client.queue.length);
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", chunk => {
      size += chunk.length;
      if (size > 16 * 1024 * 1024) {
        reject(new Error("Request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function jsonResponse(response, status, payload) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function boundPort(server) {
  const address = server.address();
  return typeof address === "object" && address ? address.port : port;
}

function isMainModule() {
  return process.argv[1]
    ? path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
    : false;
}

export function resetBridgeStateForTests() {
  for (const client of clients) {
    try {
      client.audioStream?.destroy();
      client.socket?.destroy();
    } catch {}
  }
  clients.clear();
  httpClients.clear();
  durableStateBySelection.clear();
  readStateSignaturesBySelection.clear();
  sessionFileByThread.clear();
  latestDurableState = null;
  codexAppServer?.dispose?.();
  codexAppServer = null;
}

function frameHeader(length) {
  if (length < 126) {
    return Buffer.from([0x81, length]);
  }
  if (length < 65536) {
    const header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
    return header;
  }
  const header = Buffer.alloc(10);
  header[0] = 0x81;
  header[1] = 127;
  header.writeBigUInt64BE(BigInt(length), 2);
  return header;
}

function closeClient(client, options = {}) {
  const hadClient = clients.delete(client);
  stopAudio(client);
  if (options.replyClose && !client.socket.destroyed) {
    try {
      client.socket.write(Buffer.from([0x88, 0x00]));
    } catch {}
  }
  try {
    client.socket.end();
  } catch {}
  if (hadClient) {
    console.log(`watch disconnected (${clients.size} client${clients.size === 1 ? "" : "s"})`);
  }
}

function lanAddress() {
  const candidates = [];
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const entry of addresses || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        candidates.push(entry);
      }
    }
  }
  return candidates.find(entry => !entry.address.endsWith(".1"))?.address
    || candidates[0]?.address
    || "127.0.0.1";
}

function localHostName() {
  if (process.env.CODEX_WATCH_LOCAL_HOSTNAME) {
    return process.env.CODEX_WATCH_LOCAL_HOSTNAME;
  }
  try {
    return execFileSync("scutil", ["--get", "LocalHostName"], { encoding: "utf8" }).trim()
      || os.hostname().split(".")[0];
  } catch {
    return os.hostname().split(".")[0];
  }
}

function logConnection(label, socket) {
  const summary = `${label} (${clients.size} client${clients.size === 1 ? "" : "s"})`;
  if (verboseBridgeLogging) {
    console.log(summary, `from ${socket.remoteAddress || "unknown"}:${socket.remotePort || "?"}`);
  } else {
    console.log(summary);
  }
}

function logVerbose(...args) {
  if (verboseBridgeLogging) {
    console.log(...args);
  }
}

function warnBridge(message, error) {
  if (verboseBridgeLogging) {
    console.warn(message, error?.message || error);
  } else {
    console.warn(message);
  }
}

function errorBridge(message, error) {
  if (verboseBridgeLogging) {
    console.error(message, error?.message || error);
  } else {
    console.error(message);
  }
}

function redactedSelectionID(value) {
  if (typeof value !== "string" || value.length === 0) {
    return "none";
  }
  if (value.startsWith("project:")) {
    return "project";
  }
  if (value.startsWith("new-chat:")) {
    return "new-chat";
  }
  return value.length > 12 ? `${value.slice(0, 8)}...` : value;
}

function maybeOpenCodex() {
  if (process.env.CODEX_WATCH_OPEN_CODEX !== "1") {
    return;
  }
  execFile("open", ["-a", "Codex"], () => {});
}
