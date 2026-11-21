// Reproduce the 0.1.200 session-import boundary using only a synthetic home.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const moduleDigest = "35705f78b6f41301eda4ef6c5404b24332eb12bfe38c59f540fc8c5d4bcf9887";
const decision = "我确认首版由私有云改用 iCloud。";

async function loadPackagedImporter(archive, scratch) {
  const bytes = await readFile(archive);
  const headerLength = bytes.readUInt32LE(12);
  const header = JSON.parse(bytes.toString("utf8", 16, 16 + headerLength));
  const file = header.files.src.files.main.files["memory-import.mjs"];
  const start = 8 + bytes.readUInt32LE(4) + Number(file.offset);
  const source = bytes.subarray(start, start + file.size);
  assert.equal(createHash("sha256").update(source).digest("hex"), moduleDigest);
  const modulePath = path.join(scratch, "memory-import.mjs");
  await writeFile(modulePath, source);
  return (await import(pathToFileURL(modulePath).href)).MemoryImportService;
}

async function trial(Importer, homeDir, changedAt) {
  const sessions = path.join(homeDir, ".codex", "sessions");
  await mkdir(sessions, { recursive: true });
  const rows = [{
    type: "session_meta",
    payload: { cwd: path.join(homeDir, "work", "DemoVault"), git: { branch: "pilot" } },
  }];
  for (let turn = 1; turn <= 24; turn++) {
    const user = turn % 2 === 1;
    const text = "Turn-" + String(turn).padStart(2, "0") + "：" + (turn === changedAt ? decision : "合成讨论样本。");
    rows.push({
      type: "response_item", timestamp: "2026-11-01T12:00:00Z",
      payload: {
        type: "message", role: user ? "user" : "assistant",
        content: [{ type: user ? "input_text" : "output_text", text }],
      },
    });
  }
  await writeFile(path.join(sessions, "sample.jsonl"), rows.map(r => JSON.stringify(r)).join("\n"));
  const boundary = new Error("Synthetic receiver intercepted the import");
  let item;
  const runtime = {
    async authedFetch(route, options) {
      assert.equal(route, "/_memory-import");
      const { items } = JSON.parse(options.body);
      assert.equal(items.length, 1);
      [item] = items;
      throw boundary;
    },
  };
  const importer = new Importer({ homeDir, root: path.join(homeDir, "out"), runtime });
  await assert.rejects(importer.import(["codex"]), error => error === boundary);
  assert.equal(item.kind, "session");
  assert.equal(item.source, "codex");
  const selected = new Set(item.content.match(/Turn-\d+/g));
  assert.equal(selected.size, 14);
  const retained = item.content.includes(decision);
  assert.equal(retained, changedAt === 9);
  console.log(JSON.stringify({ changedAt, distinctTurns: selected.size, retained }));
}

if (!process.argv[2]) throw new Error("Usage: node persom-200-session.mjs <0.1.200 app.asar>");
const scratch = await mkdtemp(path.join(tmpdir(), "persom-session-fixture-"));
try {
  const Importer = await loadPackagedImporter(process.argv[2], scratch);
  for (const turn of [7, 9]) await trial(Importer, path.join(scratch, String(turn)), turn);
} finally {
  await rm(scratch, { recursive: true, force: true });
}
