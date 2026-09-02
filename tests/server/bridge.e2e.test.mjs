import assert from "node:assert/strict";
import fs from "node:fs/promises";
import net from "node:net";
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
    delete process.env.CODEX_WATCH_AUTH_TOKEN;
    resetBridgeStateForTests();
    server = startBridge({ port: 0, host: "127.0.0.1" });
    await once(server, "listening");
  });

  afterEach(async () => {
    resetBridgeStateForTests();
    await closeServer(server);
    server = null;
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

  test("hello resolves placeholder selection to the real Codex chat", async () => {
    const response = await postMessage("selection-client", {
      type: "hello",
      pet: "codex",
      capabilities: ["project-chat-picker"],
      project: "project-1",
      chat: "chat-1",
      projectIndex: 0,
      chatIndex: 0
    });

    assert.equal(response.messages.at(-1)?.chat, "thread-e2e-1");
    assert.equal(response.messages.at(-1)?.project, `project:${path.join(tempDir, "project-one")}`);
  });

  test("broadcasts preserve each watch client selected pet", async () => {
    await writeSessionFixture(tempDir, {
      threadId: "thread-e2e-2",
      cwd: path.join(tempDir, "project-two"),
      prompt: "Second fixture prompt"
    });
    await postMessage("fireball-watch", {
      type: "hello",
      pet: "fireball",
      capabilities: ["codex-pets"],
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1"
    });
    await postMessage("codex-watch", {
      type: "hello",
      pet: "codex",
      capabilities: ["codex-pets"],
      project: `project:${path.join(tempDir, "project-two")}`,
      chat: "thread-e2e-2"
    });

    await postMessage("codex-watch", {
      type: "state",
      pet: "codex",
      state: "thinking",
      title: "Codex is thinking",
      body: "Working on it"
    });

    const fireballMessages = await poll("fireball-watch");
    assert.equal(fireballMessages.messages.at(-1)?.pet, "fireball");
    assert.equal(fireballMessages.messages.at(-1)?.chat, "thread-e2e-1");
  });

  test("chat-opened returns ordered recent user and assistant messages", async () => {
    process.env.CODEX_WATCH_MOCK_RESUME_HISTORY = JSON.stringify({
      thread: {
        id: "thread-e2e-1",
        status: { type: "idle" },
        turns: [
          {
            id: "turn-1",
            status: "completed",
            items: [
              {
                id: "user-1",
                type: "userMessage",
                content: [{ type: "inputText", text: "First question" }]
              },
              {
                id: "agent-1",
                type: "agentMessage",
                text: "First answer"
              }
            ]
          },
          {
            id: "turn-2",
            status: "completed",
            items: [
              {
                id: "user-2",
                type: "userMessage",
                content: [{ type: "inputText", text: "Second question" }]
              },
              {
                id: "agent-2",
                type: "agentMessage",
                text: "Second answer"
              }
            ]
          }
        ]
      }
    });

    await postMessage("history-client", {
      type: "hello",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });
    await postMessage("history-client", {
      type: "chat-opened",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    const messages = await pollUntil("history-client", allMessages => {
      return allMessages.some(message => message.type === "conversation");
    });
    const conversation = messages.findLast(message => message.type === "conversation");

    assert.deepEqual(conversation?.entries.map(entry => [entry.role, entry.text]), [
      ["user", "First question"],
      ["assistant", "First answer"],
      ["user", "Second question"],
      ["assistant", "Second answer"]
    ]);
    assert.equal(conversation?.hasMore, false);
  });

  test("chat-opened falls back to session JSONL and limits the response to 20 messages", async () => {
    process.env.CODEX_WATCH_MOCK_RESUME_ERROR = "1";
    const fixtureFile = sessionFixturePath(tempDir, "thread-e2e-1");
    const events = [];
    for (let index = 1; index <= 11; index += 1) {
      events.push({
        type: "response_item",
        payload: {
          id: `user-${index}`,
          type: "message",
          role: "user",
          content: [{ type: "input_text", text: `Question ${index}` }]
        }
      });
      events.push({
        type: "response_item",
        payload: {
          id: `assistant-${index}`,
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: `Answer ${index}` }]
        }
      });
    }
    await fs.appendFile(fixtureFile, `${events.map(event => JSON.stringify(event)).join("\n")}\n`);

    await postMessage("fallback-history-client", {
      type: "hello",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });
    const opened = await postMessage("fallback-history-client", {
      type: "chat-opened",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    const messages = opened.messages.some(message => message.type === "conversation")
      ? opened.messages
      : await pollUntil("fallback-history-client", allMessages => {
        return allMessages.some(message => message.type === "conversation");
      });
    const conversation = messages.findLast(message => message.type === "conversation");

    assert.equal(conversation?.entries.length, 20);
    assert.equal(conversation?.entries[0]?.text, "Question 2");
    assert.equal(conversation?.entries.at(-1)?.text, "Answer 11");
    assert.equal(conversation?.hasMore, true);
  });

  test("chat-opened reads legacy type-message JSONL when app-server is unavailable", async () => {
    process.env.CODEX_WATCH_MOCK_RESUME_ERROR = "1";

    await postMessage("legacy-history-client", {
      type: "hello",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });
    const opened = await postMessage("legacy-history-client", {
      type: "chat-opened",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });
    const messages = opened.messages.some(message => message.type === "conversation")
      ? opened.messages
      : await pollUntil("legacy-history-client", allMessages => {
        return allMessages.some(message => message.type === "conversation");
      });
    const conversation = messages.findLast(message => message.type === "conversation");

    assert.deepEqual(conversation?.entries.map(entry => [entry.role, entry.text]), [
      ["user", "Initial fixture prompt"]
    ]);
    assert.equal(conversation?.hasMore, false);
  });

  test("chat-opened follows app-server item pagination to fill the latest 20 messages", async () => {
    const descendingItems = [];
    for (let index = 11; index >= 1; index -= 1) {
      descendingItems.push({
        turnId: `turn-${index}`,
        item: { id: `assistant-${index}`, type: "agentMessage", text: `Answer ${index}` }
      });
      descendingItems.push({
        turnId: `turn-${index}`,
        item: {
          id: `user-${index}`,
          type: "userMessage",
          content: [{ type: "inputText", text: `Question ${index}` }]
        }
      });
    }
    process.env.CODEX_WATCH_MOCK_RESUME_HISTORY = JSON.stringify({
      thread: {
        id: "thread-e2e-1",
        status: { type: "idle" },
        turns: [{
          id: "turn-11",
          status: "completed",
          items: [
            { id: "user-11", type: "userMessage", content: [{ type: "inputText", text: "Question 11" }] },
            { id: "assistant-11", type: "agentMessage", text: "Answer 11" }
          ]
        }]
      },
      itemsBackwardsCursor: "items-head"
    });
    process.env.CODEX_WATCH_MOCK_ITEMS_LIST = JSON.stringify({
      data: descendingItems,
      nextCursor: "older-items",
      backwardsCursor: "items-head"
    });

    await postMessage("paginated-history-client", {
      type: "hello",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });
    await postMessage("paginated-history-client", {
      type: "chat-opened",
      pet: "codex",
      project: `project:${path.join(tempDir, "project-one")}`,
      chat: "thread-e2e-1",
      projectIndex: 0,
      chatIndex: 0
    });

    const messages = await pollUntil("paginated-history-client", allMessages => {
      return allMessages.some(message => message.type === "conversation");
    });
    const conversation = messages.findLast(message => message.type === "conversation");

    assert.equal(conversation?.entries.length, 20);
    assert.equal(conversation?.entries[0]?.text, "Question 2");
    assert.equal(conversation?.entries.at(-1)?.text, "Answer 11");
    assert.equal(conversation?.hasMore, true);
  });

  test("WebSocket access remains available when authentication is disabled", async () => {
    assert.equal(await websocketStatus(), 101);
  });

  test("optional bearer authentication protects every command transport", async () => {
    process.env.CODEX_WATCH_AUTH_TOKEN = "test-secret";
    await restartServer();

    const message = { type: "hello", pet: "codex", capabilities: ["codex-pets"] };
    for (const token of [null, "wrong-secret"]) {
      const messageResponse = await requestMessage("auth-client", message, token);
      assert.equal(messageResponse.status, 401);
      assert.equal(messageResponse.body.error, "Unauthorized");
      assert.equal(messageResponse.challenge, 'Bearer realm="codex-watch"');

      const pollResponse = await requestPoll("auth-client", token);
      assert.equal(pollResponse.status, 401);
      assert.equal(pollResponse.body.error, "Unauthorized");

      assert.equal(await websocketStatus(token), 401);
    }

    const acceptedMessage = await requestMessage("auth-client", message, "test-secret");
    assert.equal(acceptedMessage.status, 200);
    assert.equal(acceptedMessage.body.ok, true);

    const acceptedPoll = await requestPoll("auth-client", "test-secret");
    assert.equal(acceptedPoll.status, 200);
    assert.equal(acceptedPoll.body.ok, true);

    assert.equal(await websocketStatus("test-secret"), 101);
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
  const directory = path.dirname(sessionFixturePath(root, threadId));
  await fs.mkdir(directory, { recursive: true });
  await fs.mkdir(cwd, { recursive: true });
  const file = sessionFixturePath(root, threadId);
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

function sessionFixturePath(root, threadId) {
  return path.join(root, "2026", "05", "24", `${threadId}.jsonl`);
}

function baseURL() {
  const address = server.address();
  assert.equal(typeof address, "object");
  return `http://127.0.0.1:${address.port}`;
}

async function postMessage(client, message) {
  return (await requestMessage(client, message)).body;
}

async function requestMessage(client, message, token = null) {
  const response = await fetch(`${baseURL()}/codex-watch/message?client=${client}`, {
    method: "POST",
    headers: requestHeaders(token, { "content-type": "application/json" }),
    body: JSON.stringify(message)
  });
  return {
    status: response.status,
    challenge: response.headers.get("www-authenticate"),
    body: await response.json()
  };
}

async function poll(client) {
  return (await requestPoll(client)).body;
}

async function requestPoll(client, token = null) {
  const response = await fetch(`${baseURL()}/codex-watch/poll?client=${client}`, {
    headers: requestHeaders(token)
  });
  return {
    status: response.status,
    challenge: response.headers.get("www-authenticate"),
    body: await response.json()
  };
}

function requestHeaders(token, headers = {}) {
  return token ? { ...headers, authorization: `Bearer ${token}` } : headers;
}

function websocketStatus(token = null) {
  const address = server.address();
  assert.equal(typeof address, "object");
  return new Promise((resolve, reject) => {
    const socket = net.connect(address.port, "127.0.0.1", () => {
      const headers = [
        "GET /codex-watch HTTP/1.1",
        `Host: 127.0.0.1:${address.port}`,
        "Connection: Upgrade",
        "Upgrade: websocket",
        `Sec-WebSocket-Key: ${Buffer.alloc(16, 7).toString("base64")}`,
        "Sec-WebSocket-Version: 13"
      ];
      if (token) {
        headers.push(`Authorization: Bearer ${token}`);
      }
      socket.write(`${headers.join("\r\n")}\r\n\r\n`);
    });
    let response = "";
    socket.on("data", chunk => {
      response += chunk.toString("latin1");
      const match = /^HTTP\/1\.1 (\d{3})/m.exec(response);
      if (!match) {
        return;
      }
      socket.destroy();
      resolve(Number(match[1]));
    });
    socket.on("error", reject);
  });
}

async function restartServer() {
  resetBridgeStateForTests();
  await closeServer(server);
  server = startBridge({ port: 0, host: "127.0.0.1" });
  await once(server, "listening");
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
