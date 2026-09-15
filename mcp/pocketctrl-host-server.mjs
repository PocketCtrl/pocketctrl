#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0

const baseURL = configuredBaseURL();

const tools = [
  {
    name: "pocketctrl_host_status",
    description: "Get current PocketCtrl host status and settings from the running Mac app.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  },
  {
    name: "pocketctrl_host_pairing_info",
    description: "Get the current pairing code and QR payload URL for connecting a viewer.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  },
  {
    name: "pocketctrl_host_start",
    description: "Start hosting from the running Mac app.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  },
  {
    name: "pocketctrl_host_stop",
    description: "Stop hosting from the running Mac app.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  },
  {
    name: "pocketctrl_host_restart",
    description: "Restart hosting with the current settings.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  },
  {
    name: "pocketctrl_host_regenerate_pairing",
    description: "Generate a new host pairing key. Further control calls must use the new key shown by the Mac app.",
    inputSchema: {
      type: "object",
      properties: {},
      additionalProperties: false
    }
  },
  {
    name: "pocketctrl_host_set_settings",
    description: "Update host settings. If hosting is active, the app applies the change by restarting hosting.",
    inputSchema: {
      type: "object",
      properties: {
        destinationAddress: { type: "string" },
        videoPort: { type: "string" },
        audioPort: { type: "string" },
        inputPort: { type: "string" },
        captureWidth: { type: "number" },
        fps: { type: "number" },
        bitrateMbps: { type: "number" },
        adaptiveBitrateEnabled: { type: "boolean" },
        audioEnabled: { type: "boolean" },
        remoteInputEnabled: { type: "boolean" },
        keepAwakeWhileHosting: { type: "boolean" },
        autoStartHosting: { type: "boolean" },
        localDiscoveryEnabled: { type: "boolean" },
        displayID: { type: "number" }
      },
      additionalProperties: false
    }
  }
];

let buffer = Buffer.alloc(0);

process.stdin.on("data", chunk => {
  buffer = Buffer.concat([buffer, chunk]);
  readMessages();
});

function readMessages() {
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) return;

    const header = buffer.slice(0, headerEnd).toString("utf8");
    const match = /content-length:\s*(\d+)/i.exec(header);
    if (!match) {
      buffer = buffer.slice(headerEnd + 4);
      continue;
    }

    const length = Number(match[1]);
    const start = headerEnd + 4;
    const end = start + length;
    if (buffer.length < end) return;

    const raw = buffer.slice(start, end).toString("utf8");
    buffer = buffer.slice(end);

    let message;
    try {
      message = JSON.parse(raw);
    } catch (error) {
      continue;
    }

    handleMessage(message).catch(error => {
      if (message && Object.prototype.hasOwnProperty.call(message, "id")) {
        send({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32000, message: error.message || String(error) }
        });
      }
    });
  }
}

async function handleMessage(message) {
  if (!message || message.jsonrpc !== "2.0") return;

  if (!Object.prototype.hasOwnProperty.call(message, "id")) {
    return;
  }

  switch (message.method) {
    case "initialize":
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "pocketctrl-host-mcp", version: "0.1.0" }
        }
      });
      return;

    case "tools/list":
      send({ jsonrpc: "2.0", id: message.id, result: { tools } });
      return;

    case "tools/call": {
      const result = await callTool(message.params?.name, message.params?.arguments || {});
      send({ jsonrpc: "2.0", id: message.id, result });
      return;
    }

    default:
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: `Unknown method: ${message.method}` }
      });
  }
}

async function callTool(name, args) {
  switch (name) {
    case "pocketctrl_host_status":
      return textResult(await hostRequest("GET", "/status"));
    case "pocketctrl_host_pairing_info":
      return textResult(await hostRequest("GET", "/pairing"));
    case "pocketctrl_host_start":
      return textResult(await hostRequest("POST", "/start"));
    case "pocketctrl_host_stop":
      return textResult(await hostRequest("POST", "/stop"));
    case "pocketctrl_host_restart":
      return textResult(await hostRequest("POST", "/restart"));
    case "pocketctrl_host_regenerate_pairing":
      return textResult(await hostRequest("POST", "/pairing/regenerate"));
    case "pocketctrl_host_set_settings":
      return textResult(await hostRequest("POST", "/settings", args));
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

async function hostRequest(method, path, body) {
  const token = (process.env.POCKETCTRL_CONTROL_TOKEN || "").trim();
  if (!token) {
    throw new Error("POCKETCTRL_CONTROL_TOKEN is required.");
  }

  const headers = {
    accept: "application/json",
    authorization: `Bearer ${token}`
  };
  if (body) headers["content-type"] = "application/json";

  const response = await fetch(new URL(path, baseURL), {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined
  });

  const text = await response.text();
  if (!response.ok) {
    throw new Error(`PocketCtrl host API failed (${response.status}): ${text}`);
  }

  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

function configuredBaseURL() {
  const value = process.env.POCKETCTRL_HOST_URL || "http://127.0.0.1:47777";
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("POCKETCTRL_HOST_URL must be a valid loopback HTTP URL");
  }

  if (url.protocol !== "http:" || !["127.0.0.1", "localhost"].includes(url.hostname) || url.username || url.password) {
    throw new Error("POCKETCTRL_HOST_URL must use HTTP on 127.0.0.1 or localhost");
  }
  url.pathname = "/";
  url.search = "";
  url.hash = "";
  return url;
}

function textResult(text) {
  return {
    content: [{ type: "text", text }]
  };
}

function send(message) {
  const json = JSON.stringify(message);
  process.stdout.write(`Content-Length: ${Buffer.byteLength(json, "utf8")}\r\n\r\n${json}`);
}
