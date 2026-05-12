// FILE: codex-auth-store-monitor.test.js
// Purpose: Verifies Codex auth identity changes are detected without token exposure.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/codex-auth-store-monitor

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const {
  createCodexAuthStoreMonitor,
  readCodexAuthStoreSnapshot,
} = require("../src/codex-auth-store-monitor");

test("auth store snapshot ignores token refresh churn for the same account", () => {
  const codexHome = createTempCodexHome();

  try {
    writeAuth(codexHome, {
      last_refresh: "2026-05-13T01:00:00Z",
      tokens: {
        account_id: "account-a",
        access_token: "access-token-one",
        refresh_token: "refresh-token-one",
      },
    });
    const first = readCodexAuthStoreSnapshot({ codexHome });

    writeAuth(codexHome, {
      last_refresh: "2026-05-13T02:00:00Z",
      tokens: {
        account_id: "account-a",
        access_token: "access-token-two",
        refresh_token: "refresh-token-two",
      },
    });
    const second = readCodexAuthStoreSnapshot({ codexHome });

    assert.equal(first.kind, "chatgpt");
    assert.equal(second.kind, "chatgpt");
    assert.equal(first.fingerprint, second.fingerprint);
  } finally {
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("auth store snapshot changes when the ChatGPT account changes", () => {
  const codexHome = createTempCodexHome();

  try {
    writeAuth(codexHome, {
      tokens: {
        account_id: "account-a",
      },
    });
    const first = readCodexAuthStoreSnapshot({ codexHome });

    writeAuth(codexHome, {
      tokens: {
        account_id: "account-b",
      },
    });
    const second = readCodexAuthStoreSnapshot({ codexHome });

    assert.equal(first.kind, "chatgpt");
    assert.equal(second.kind, "chatgpt");
    assert.notEqual(first.fingerprint, second.fingerprint);
  } finally {
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("auth store monitor reports identity changes through explicit checks", () => {
  const codexHome = createTempCodexHome();

  try {
    writeAuth(codexHome, {
      tokens: {
        account_id: "account-a",
      },
    });
    const changes = [];
    const monitor = createCodexAuthStoreMonitor({
      codexHome,
      onChange: (change) => changes.push(change),
    });

    writeAuth(codexHome, {
      tokens: {
        account_id: "account-b",
      },
    });

    assert.equal(monitor.checkNow(), true);
    assert.equal(monitor.checkNow(), false);
    assert.equal(changes.length, 1);
    assert.equal(changes[0].previous.kind, "chatgpt");
    assert.equal(changes[0].current.kind, "chatgpt");
    assert.notEqual(changes[0].previous.fingerprint, changes[0].current.fingerprint);
  } finally {
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

test("auth store snapshot can derive identity from a JWT subject fallback", () => {
  const codexHome = createTempCodexHome();

  try {
    writeAuth(codexHome, {
      tokens: {
        id_token: fakeJwt({
          iss: "https://auth.example.test",
          sub: "subject-a",
        }),
      },
    });
    const first = readCodexAuthStoreSnapshot({ codexHome });

    writeAuth(codexHome, {
      tokens: {
        id_token: fakeJwt({
          iss: "https://auth.example.test",
          sub: "subject-b",
        }),
      },
    });
    const second = readCodexAuthStoreSnapshot({ codexHome });

    assert.equal(first.kind, "chatgpt");
    assert.equal(second.kind, "chatgpt");
    assert.notEqual(first.fingerprint, second.fingerprint);
  } finally {
    fs.rmSync(codexHome, { recursive: true, force: true });
  }
});

function createTempCodexHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "remodex-auth-store-"));
}

function writeAuth(codexHome, auth) {
  fs.mkdirSync(codexHome, { recursive: true });
  fs.writeFileSync(path.join(codexHome, "auth.json"), JSON.stringify(auth, null, 2));
}

function fakeJwt(payload) {
  return [
    base64UrlEncode({ alg: "none", typ: "JWT" }),
    base64UrlEncode(payload),
    "signature",
  ].join(".");
}

function base64UrlEncode(value) {
  return Buffer
    .from(JSON.stringify(value), "utf8")
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}
