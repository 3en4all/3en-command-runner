import { Type } from "typebox";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { promises as fs } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const ROOT = path.resolve("C:\\3EN-Agent\\workbench");
const BACKUP_ROOT = path.join(ROOT, ".3en-job-backups");

function insideRoot(input) {
  const p = path.resolve(String(input || ""));
  const rootLower = ROOT.toLowerCase();
  const pLower = p.toLowerCase();
  if (pLower !== rootLower && !pLower.startsWith(rootLower + path.sep.toLowerCase())) {
    throw new Error(`PATH_OUTSIDE_ALLOWED_ROOT: ${p}`);
  }
  return p;
}

async function rejectSymlink(p) {
  try {
    const s = await fs.lstat(p);
    if (s.isSymbolicLink()) throw new Error(`SYMLINK_TARGET_REJECTED: ${p}`);
  } catch (e) {
    if (e?.code !== "ENOENT") throw e;
  }
}

async function sha256(p) {
  const b = await fs.readFile(p);
  return crypto.createHash("sha256").update(b).digest("hex");
}

async function makeBackup(p) {
  try {
    await fs.access(p);
  } catch {
    return null;
  }
  await rejectSymlink(p);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const dir = path.join(BACKUP_ROOT, `${stamp}-${crypto.randomUUID()}`);
  await fs.mkdir(dir, { recursive: true });
  const dst = path.join(dir, path.basename(p));
  await fs.copyFile(p, dst);
  return dst;
}

async function atomicWrite(target, content) {
  await fs.mkdir(path.dirname(target), { recursive: true });
  await rejectSymlink(target);
  const tmp = `${target}.3en-tmp-${crypto.randomUUID()}`;
  await fs.writeFile(tmp, content, { encoding: "utf8", flag: "wx" });
  await fs.rename(tmp, target);
}

const Params = Type.Object({
  operation: Type.Union([
    Type.Literal("write"),
    Type.Literal("replace"),
    Type.Literal("copy"),
    Type.Literal("move"),
    Type.Literal("delete_controlled")
  ]),
  path: Type.Optional(Type.String()),
  source: Type.Optional(Type.String()),
  destination: Type.Optional(Type.String()),
  content: Type.Optional(Type.String()),
  find: Type.Optional(Type.String()),
  replacement: Type.Optional(Type.String())
}, { additionalProperties: false });

export default definePluginEntry({
  id: "3en-job-executor",
  name: "3EN Job Executor",
  description: "Deterministic 3EN Agent file operations under a fixed workspace allowlist.",
  register(api) {
    api.registerTool({
      name: "3en_job",
      description: "Execute one deterministic file operation inside C:/3EN-Agent/workbench. No shell, network, or model reasoning.",
      parameters: Params,
      async execute(_id, params) {
        const op = params.operation;
        let target = null;
        let backup = null;
        let source = null;
        let destination = null;

        if (op === "write") {
          target = insideRoot(params.path);
          if (typeof params.content !== "string") throw new Error("CONTENT_REQUIRED");
          backup = await makeBackup(target);
          await atomicWrite(target, params.content);
        } else if (op === "replace") {
          target = insideRoot(params.path);
          if (typeof params.find !== "string" || typeof params.replacement !== "string") throw new Error("FIND_AND_REPLACEMENT_REQUIRED");
          await rejectSymlink(target);
          const current = await fs.readFile(target, "utf8");
          const parts = current.split(params.find);
          if (parts.length !== 2) throw new Error(`REPLACE_EXPECTED_EXACTLY_ONE_MATCH: ${parts.length - 1}`);
          backup = await makeBackup(target);
          await atomicWrite(target, parts[0] + params.replacement + parts[1]);
        } else if (op === "copy") {
          source = insideRoot(params.source);
          destination = insideRoot(params.destination);
          await rejectSymlink(source);
          await rejectSymlink(destination);
          backup = await makeBackup(destination);
          await fs.mkdir(path.dirname(destination), { recursive: true });
          await fs.copyFile(source, destination);
          target = destination;
        } else if (op === "move") {
          source = insideRoot(params.source);
          destination = insideRoot(params.destination);
          await rejectSymlink(source);
          await rejectSymlink(destination);
          backup = await makeBackup(destination);
          await fs.mkdir(path.dirname(destination), { recursive: true });
          await fs.rename(source, destination);
          target = destination;
        } else if (op === "delete_controlled") {
          target = insideRoot(params.path);
          await rejectSymlink(target);
          backup = await makeBackup(target);
          if (!backup) throw new Error("DELETE_TARGET_MISSING");
          await fs.unlink(target);
        } else {
          throw new Error(`UNSUPPORTED_OPERATION: ${op}`);
        }

        let exists = false;
        let hash = null;
        if (target) {
          try {
            await fs.access(target);
            exists = true;
            hash = await sha256(target);
          } catch {}
        }

        const details = {
          ok: true,
          operation: op,
          allowedRoot: ROOT,
          target,
          source,
          destination,
          backup,
          existsAfter: exists,
          sha256After: hash
        };
        return {
          content: [{ type: "text", text: JSON.stringify(details) }],
          details
        };
      }
    });
  }
});
