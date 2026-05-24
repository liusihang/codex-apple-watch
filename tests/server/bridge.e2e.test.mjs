import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, test } from "node:test";
import { once } from "node:events";
import { resetBridgeStateForTests, startBridge } from "../../bridge/codex-watch-bridge.mjs";

let server;
let tempDir;
let originalEnv;

describe("Codex Watch bridge E2E", { concurrency: false }, () => {
  beforeEach(async () => {
    originalEnv = { ...process.env };
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "codex-watch-bridge-test-"));
    await writeSessionFixture(tempDir, {
      threadId: "thread-e2e-1",
      cwd: path.join(tempDir, "project-one"),
      prompt: "Initial fixture prompt"
    });
    process.env.CODEX_SESSIONS_DIR = tempDir;
    process.env.CODEX_WATCH_MOCK_APP_SERVER = "1";
    process.env.CODEX_WATCH_MOCK_REPLY = "Mock **reply** with `inlineCode`.";
    resetBridgeStateForTests();
    server = startBridge({ port: 0, host: "127.0.0.1" });
    await once(server, "listening");
  });

  afterEach(async () => {
    await closeServer(server);
    server = null;
    resetBridgeStateForTests();
    if (tempDir) {
      await fs.rm(tempDir, { recursive: true, force: true });
      tempDir = null;
    }
    process.env = originalEnv;
  });

  test("hello returns bridge state and real picker items from Codex sessions", async () => {
    const response = await postMessage("hello-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets", "project-chat-picker"]
    });

    assert.equal(response.ok, true);
    assert.equal(response.messages.at(-1)?.title, "Codex");
    assert.equal(response.messages.at(-1)?.body, "Bridge ready");
    assert.ok(response.messages.at(-1)?.items.some(item => item.chat === "thread-e2e-1"));
    assert.ok(response.messages.at(-1)?.items.some(item => item.kind === "project"));
  });

  test("transcript-send starts a Codex turn and streams status events back to the watch", async () => {
    const longReply = "This response sends transcripts into Codex chats without losing the expanded markdown body. It includes enough detail to exceed the card preview limit while preserving the complete text for the watch reader, including `inlineCode` and **bold** markdown.";
    process.env.CODEX_WATCH_MOCK_REPLY = longReply;

    await postMessage("send-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"]
    });

    const sendResponse = await postMessage("send-client", {
      type: "transcript-send",
      pet: "codex",
      text: "Summarize `inlineCode` please.",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      target: "chat"
    });

    assert.equal(sendResponse.ok, true);
    assert.ok(sendResponse.messages.some(message => message.title === "Sending"));

    const messages = await pollUntil("send-client", allMessages => {
      const titles = allMessages.map(message => message.title);
      return titles.includes("Codex is thinking") && titles.includes("Codex replied");
    });

    assert.equal(messages.find(message => message.title === "Codex is thinking")?.state, "thinking");
    assert.equal(messages.find(message => message.title === "Codex is thinking")?.body, "Working on it");
    assert.ok(messages.some(message => message.title === "Codex is replying"));
    assert.ok(messages.some(message => message.body?.includes("inlineCode")));
    const finalReply = messages.findLast(message => message.title === "Codex replied");
    assert.equal(finalReply?.state, "review");
    assert.equal(finalReply?.text, longReply);
    assert.ok((finalReply?.body?.length || 0) < longReply.length);
    assert.match(finalReply?.body || "", /\.\.\.$/);
  });

  test("reconnecting clients receive the last unread reply until it is read", async () => {
    const project = `project:${path.join(tempDir, "project-one")}`;

    await postMessage("replay-source", {
      type: "state",
      pet: "codex",
      state: "review",
      title: "Codex replied",
      body: "Unread preview",
      text: "Unread full body",
      project,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    const replay = await postMessage("replay-target", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"],
      project,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    assert.equal(replay.messages.at(-1)?.title, "Codex replied");
    assert.equal(replay.messages.at(-1)?.state, "review");
    assert.equal(replay.messages.at(-1)?.text, "Unread full body");

    await postMessage("replay-target", {
      type: "message-read",
      pet: "codex",
      project,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    const afterRead = await postMessage("replay-after-read", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"],
      project,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    assert.equal(afterRead.messages.at(-1)?.title, "Codex");
    assert.equal(afterRead.messages.at(-1)?.body, "Bridge ready");
  });

  test("reconnecting clients receive thinking state", async () => {
    const project = `project:${path.join(tempDir, "project-one")}`;

    await postMessage("thinking-source", {
      type: "state",
      pet: "codex",
      state: "thinking",
      title: "Codex is thinking",
      body: "Working on it",
      project,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    const replay = await postMessage("thinking-target", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"],
      project,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    assert.equal(replay.messages.at(-1)?.title, "Codex is thinking");
    assert.equal(replay.messages.at(-1)?.state, "thinking");
    assert.equal(replay.messages.at(-1)?.body, "Working on it");
  });

  test("hello refreshes the selected chat state from Codex on app open", async () => {
    process.env.CODEX_WATCH_MOCK_RESUME_REPLY = "Reply created while the watch app was closed.";

    await postMessage("refresh-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"],
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    const messages = await pollUntil("refresh-client", allMessages => {
      return allMessages.some(message => message.title === "Codex replied");
    });

    const refreshed = messages.findLast(message => message.title === "Codex replied");
    assert.equal(refreshed?.state, "review");
    assert.equal(refreshed?.text, "Reply created while the watch app was closed.");
  });

  test("new chat transcript creates a Codex thread before starting the turn", async () => {
    const project = `project:${path.join(tempDir, "project-one")}`;

    await postMessage("new-chat-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"],
      project,
      chat: `new-chat:${project}`,
      target: "chat",
      action: "new-chat",
      newChat: true
    });

    const sendResponse = await postMessage("new-chat-client", {
      type: "transcript-send",
      pet: "codex",
      text: "Start this as a fresh chat.",
      project,
      chat: `new-chat:${project}`,
      target: "chat",
      newChat: true
    });

    assert.equal(sendResponse.ok, true);
    assert.ok(sendResponse.messages.some(message => message.title === "Starting chat"));

    const messages = await pollUntil("new-chat-client", allMessages => {
      return allMessages.some(message => message.title === "Codex replied");
    });

    const finalReply = messages.findLast(message => message.title === "Codex replied");
    assert.equal(finalReply?.state, "review");
    assert.match(finalReply?.chat || "", /^mock-new-thread-/);
    assert.equal(finalReply?.newChat, false);
  });

  test("split reply deltas preserve spaces between sentences", async () => {
    process.env.CODEX_WATCH_MOCK_REPLY_CHUNKS = JSON.stringify([
      "First sentence.",
      "Second sentence.",
      " `inlineCode` remains spaced."
    ]);

    await postMessage("split-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"]
    });

    await postMessage("split-client", {
      type: "transcript-send",
      pet: "codex",
      text: "Send split chunks.",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      target: "chat"
    });

    const messages = await pollUntil("split-client", allMessages => {
      return allMessages.some(message => message.title === "Codex replied");
    });

    const finalReply = messages.findLast(message => message.title === "Codex replied");
    assert.equal(finalReply?.text, "First sentence. Second sentence. `inlineCode` remains spaced.");
  });

  test("watch audio pipeline emits transcribing state then transcript text", async () => {
    process.env.CODEX_WATCH_TRANSCRIBE_PROVIDER = "mock";
    process.env.CODEX_WATCH_MOCK_TRANSCRIPT = "Mock transcript with `inlineCode`.";

    await postMessage("mic-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["mic-stream-pcm-f32le"]
    });

    await postMessage("mic-client", {
      type: "mic-start",
      pet: "codex",
      sampleRate: 16000,
      channels: 1
    });
    await postMessage("mic-client", {
      type: "mic-chunk",
      pet: "codex",
      sampleRate: 16000,
      channels: 1,
      encoding: "pcm-f32le",
      data: pcmFloatChunk().toString("base64")
    });
    await postMessage("mic-client", {
      type: "mic-stop",
      pet: "codex"
    });

    const messages = await pollUntil("mic-client", allMessages => {
      return allMessages.some(message => message.title === "Transcribing")
        && allMessages.some(message => message.type === "transcript");
    });

    assert.equal(messages.find(message => message.title === "Transcribing")?.state, "running");
    assert.equal(messages.find(message => message.type === "transcript")?.text, "Mock transcript with `inlineCode`.");
  });

  test("desktop runtime states are normalized for the watch", async () => {
    process.env.CODEX_WATCH_MOCK_ACTIVE_FLAG = "waitingOnApproval";

    await postMessage("state-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"]
    });

    await postMessage("state-client", {
      type: "transcript-send",
      pet: "codex",
      text: "Ship it.",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      target: "chat"
    });

    const messages = await pollUntil("state-client", allMessages => {
      return allMessages.some(message => message.title === "Approval needed");
    });

    const approval = messages.find(message => message.title === "Approval needed");
    assert.equal(approval?.state, "review");
    assert.match(approval?.body || "", /approval/i);
  });

  test("empty transcript-send returns a watch-visible failure state", async () => {
    const response = await postMessage("empty-client", {
      type: "transcript-send",
      pet: "codex",
      text: "   "
    });

    assert.equal(response.ok, true);
    assert.equal(response.messages.at(-1)?.title, "Send failed");
    assert.equal(response.messages.at(-1)?.state, "failed");
    assert.match(response.messages.at(-1)?.body || "", /empty/i);
  });
});

async function writeSessionFixture(root, { threadId, cwd, prompt }) {
  const directory = path.join(root, "2026", "05", "24");
  await fs.mkdir(directory, { recursive: true });
  await fs.mkdir(cwd, { recursive: true });
  const file = path.join(directory, `${threadId}.jsonl`);
  const lines = [
    {
      type: "session_meta",
      payload: {
        id: threadId,
        cwd,
        timestamp: "2026-05-24T15:00:00.000Z",
        source: "test"
      }
    },
    {
      type: "message",
      payload: {
        role: "user",
        message: prompt
      }
    }
  ];
  await fs.writeFile(file, `${lines.map(line => JSON.stringify(line)).join("\n")}\n`);
}

function baseURL() {
  const address = server.address();
  assert.equal(typeof address, "object");
  return `http://127.0.0.1:${address.port}`;
}

async function postMessage(client, message) {
  const response = await fetch(`${baseURL()}/codex-watch/message?client=${client}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(message)
  });
  return response.json();
}

async function poll(client) {
  const response = await fetch(`${baseURL()}/codex-watch/poll?client=${client}`);
  return response.json();
}

async function pollUntil(client, predicate, timeoutMs = 3000) {
  const startedAt = Date.now();
  const allMessages = [];

  while (Date.now() - startedAt < timeoutMs) {
    const response = await poll(client);
    allMessages.push(...response.messages);
    if (predicate(allMessages)) {
      return allMessages;
    }
    await new Promise(resolve => setTimeout(resolve, 25));
  }

  assert.fail(`Timed out waiting for messages. Saw: ${JSON.stringify(allMessages)}`);
}

function pcmFloatChunk() {
  const buffer = Buffer.alloc(64 * 4);
  for (let index = 0; index < 64; index += 1) {
    buffer.writeFloatLE(Math.sin(index / 8) * 0.25, index * 4);
  }
  return buffer;
}

function closeServer(activeServer) {
  return new Promise(resolve => {
    activeServer.close(() => resolve());
  });
}
