// FILE: codex-auth-store-monitor.js
// Purpose: Detects local Codex account identity changes without exposing auth tokens.
// Layer: CLI helper
// Exports: createCodexAuthStoreMonitor, readCodexAuthStoreSnapshot
// Depends on: crypto, fs, path, ./codex-home

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { resolveCodexHome } = require("./codex-home");

const DEFAULT_POLL_INTERVAL_MS = 3_000;

function createCodexAuthStoreMonitor({
  codexHome = resolveCodexHome(),
  fsImpl = fs,
  pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  onChange = () => {},
} = {}) {
  let timer = null;
  let lastSnapshot = readCodexAuthStoreSnapshot({ codexHome, fsImpl });

  function checkNow() {
    const nextSnapshot = readCodexAuthStoreSnapshot({ codexHome, fsImpl });
    if (nextSnapshot.fingerprint === lastSnapshot.fingerprint) {
      lastSnapshot = nextSnapshot;
      return false;
    }

    const previousSnapshot = lastSnapshot;
    lastSnapshot = nextSnapshot;
    onChange({
      previous: previousSnapshot,
      current: nextSnapshot,
    });
    return true;
  }

  return {
    start() {
      if (timer) {
        return;
      }

      timer = setInterval(checkNow, pollIntervalMs);
      timer.unref?.();
    },
    stop() {
      if (!timer) {
        return;
      }

      clearInterval(timer);
      timer = null;
    },
    checkNow,
    getSnapshot() {
      return lastSnapshot;
    },
  };
}

function readCodexAuthStoreSnapshot({
  codexHome = resolveCodexHome(),
  fsImpl = fs,
} = {}) {
  const authPath = path.join(codexHome, "auth.json");
  let rawAuth = "";
  try {
    rawAuth = fsImpl.readFileSync(authPath, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      return buildSnapshot("missing", "missing");
    }

    return buildSnapshot("unreadable", `unreadable:${error?.code || "unknown"}`);
  }

  let parsed = null;
  try {
    parsed = JSON.parse(rawAuth);
  } catch {
    return buildSnapshot("invalid", `invalid:${hashSensitiveValue(rawAuth)}`);
  }

  const identity = readAuthIdentity(parsed);
  return buildSnapshot(identity.kind, identity.fingerprintSource);
}

function readAuthIdentity(auth) {
  const accountId = readNonEmptyString(auth?.tokens?.account_id);
  if (accountId) {
    return {
      kind: "chatgpt",
      fingerprintSource: `chatgpt-account:${accountId}`,
    };
  }

  const idTokenIdentity = readJwtIdentity(auth?.tokens?.id_token);
  if (idTokenIdentity) {
    return {
      kind: "chatgpt",
      fingerprintSource: `chatgpt-jwt:${idTokenIdentity}`,
    };
  }

  const apiKey = readNonEmptyString(auth?.OPENAI_API_KEY);
  if (apiKey) {
    return {
      kind: "api-key",
      fingerprintSource: `api-key:${apiKey}`,
    };
  }

  if (auth?.tokens && typeof auth.tokens === "object") {
    return {
      kind: "token",
      fingerprintSource: `token:${hashSensitiveValue(JSON.stringify(auth.tokens))}`,
    };
  }

  return {
    kind: "empty",
    fingerprintSource: "empty",
  };
}

function readJwtIdentity(token) {
  const tokenString = readNonEmptyString(token);
  if (!tokenString) {
    return "";
  }

  const parts = tokenString.split(".");
  if (parts.length < 2) {
    return "";
  }

  try {
    const payload = JSON.parse(Buffer.from(base64UrlToBase64(parts[1]), "base64").toString("utf8"));
    const issuer = readNonEmptyString(payload?.iss);
    const subject = readNonEmptyString(payload?.sub);
    if (!subject) {
      return "";
    }

    return issuer ? `${issuer}:${subject}` : subject;
  } catch {
    return "";
  }
}

function base64UrlToBase64(value) {
  const replaced = value.replace(/-/g, "+").replace(/_/g, "/");
  const padding = (4 - (replaced.length % 4)) % 4;
  return `${replaced}${"=".repeat(padding)}`;
}

function buildSnapshot(kind, fingerprintSource) {
  return {
    kind,
    fingerprint: hashSensitiveValue(`codex-auth-store:v1:${fingerprintSource}`),
  };
}

function hashSensitiveValue(value) {
  return crypto
    .createHash("sha256")
    .update(String(value))
    .digest("hex");
}

function readNonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

module.exports = {
  createCodexAuthStoreMonitor,
  readCodexAuthStoreSnapshot,
};
