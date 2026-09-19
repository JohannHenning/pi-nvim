import type {
  ExtensionAPI,
  ToolCallEvent,
  ToolResultEvent,
  SessionStartEvent,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import * as net from "node:net";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";

/**
 * pi-nvim: Exposes a socket so external tools (like a neovim plugin)
 * can send prompts/context into a running interactive pi session.
 *
 * Repo: https://github.com/carderne/pi-nvim
 *
 * Protocol: newline-delimited JSON over a socket.
 *
 * Commands (Neovim -> pi):
 *   { "type": "prompt", "message": "..." }
 *   { "type": "prompt", "message": "...", "images": [...] }
 *   { "type": "ping" }
 *   { "type": "register_tab", "tabId": number, "cwd": string, "nvimPid"?: number }
 *   { "type": "diff_review_response", "id": string, "action": "accept"|"reject"|"modify", "content"?: string }
 *
 * Responses (pi -> Neovim):
 *   { "ok": true }
 *   { "ok": true, "type": "pong" }
 *   { "ok": false, "error": "..." }
 *   { "type": "diff_review", "id": string, "path": string, "proposed": string, "original": string, "tool": "edit"|"write", "edits"?: array }
 *
 * Unix: unix socket at /tmp/pi-nvim-sockets/<hash>-<pid>.sock, a symlink at
 * /tmp/pi-nvim-latest.sock, and a .info manifest next to each socket.
 * Windows: unix sockets don't exist, so bind a named pipe
 * \\.\pipe\pi-nvim-<hash>-<pid> instead. The manifest (.info) lives in
 * %TEMP%/pi-nvim-sockets together with a marker <hash>-<pid>.sock file so the
 * nvim side can stat for liveness; the JSON carries the connect address in
 * "socket". The nvim plugin computes the same dir from TEMP (see sockets_dir()).
 */

function cwdHash(cwd: string): string {
  return crypto.createHash("md5").update(cwd).digest("hex").slice(0, 12);
}

const IS_WIN = process.platform === "win32";
const SOCKETS_DIR = IS_WIN ? path.join(os.tmpdir(), "pi-nvim-sockets") : "/tmp/pi-nvim-sockets";
const LATEST_LINK = IS_WIN ? null : "/tmp/pi-nvim-latest.sock";

function socketBase(cwd: string): string {
  return `${cwdHash(cwd)}-${process.pid}`;
}

/** Path of the socket file (unix) or the liveness marker file (Windows). */
function socketFilePath(cwd: string): string {
  return path.join(SOCKETS_DIR, `${socketBase(cwd)}.sock`);
}

/** Actual listen address: a unix socket path or a Windows named pipe. */
function getSocketPath(cwd: string): string {
  return IS_WIN ? `\\\\.\\pipe\\pi-nvim-${socketBase(cwd)}` : socketFilePath(cwd);
}

interface TabConnection {
  conn: net.Socket;
  tabId: number;
  registered: boolean;
  cwd?: string;
  nvimPid?: number;
}

interface Session {
  server: net.Server;
  socketPath: string;
  markerFile: string;
  cwd: string;
  connections: Map<net.Socket, TabConnection>;
  pendingReviews: Map<
    string,
    { resolve: (action: string, content?: string) => void; timeout: NodeJS.Timeout; tabId: number }
  >;
}

// Store the session_start context for use in handleMessage
let sessionStartCtx: ExtensionContext | null = null;

export default function (pi: ExtensionAPI) {
  // Single session per pi process (per cwd)
  let session: Session | null = null;

  pi.on("session_start", async (event: SessionStartEvent, ctx: ExtensionContext) => {
    sessionStartCtx = ctx;
    const cwd = ctx.cwd;

    // Ensure sockets directory exists
    try {
      fs.mkdirSync(SOCKETS_DIR, { recursive: true });
    } catch {}

    const socketPath = getSocketPath(cwd);
    const markerFile = socketFilePath(cwd);

    // Clean up stale socket/marker
    try {
      fs.unlinkSync(socketPath);
    } catch {}
    try {
      fs.unlinkSync(markerFile);
    } catch {}

    const server = net.createServer((conn) => {
      // Track connection with tabId (initially unknown)
      session!.connections.set(conn, { conn, tabId: -1, registered: false });
      let buffer = "";
      conn.on("data", (data) => {
        buffer += data.toString();
        let newlineIdx: number;
        while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
          const line = buffer.slice(0, newlineIdx).trim();
          buffer = buffer.slice(newlineIdx + 1);
          if (!line) continue;
          handleMessage(line, conn);
        }
      });
      conn.on("end", () => {
        session!.connections.delete(conn);
      });
      conn.on("error", () => {
        session!.connections.delete(conn);
      });
    });

    session = {
      server,
      socketPath,
      markerFile,
      cwd,
      connections: new Map(),
      pendingReviews: new Map(),
    };

    server.listen(socketPath, () => {
      // Update latest symlink (unix only)
      if (LATEST_LINK) {
        try {
          fs.unlinkSync(LATEST_LINK);
        } catch {}
        try {
          fs.symlinkSync(socketPath, LATEST_LINK);
        } catch {}
      }

      // Register in sockets directory for discovery
      try {
        fs.mkdirSync(SOCKETS_DIR, { recursive: true });
        if (IS_WIN) fs.writeFileSync(markerFile, "");
        fs.writeFileSync(
          markerFile + ".info",
          JSON.stringify({
            socket: socketPath,
            cwd,
            pid: process.pid,
            startedAt: new Date().toISOString(),
          }),
        );
      } catch {}
    });

    server.on("error", (err) => {
      if (sessionStartCtx) {
        sessionStartCtx.ui.notify(`pi-nvim error: ${err.message}`, "error");
      }
    });
  });

  pi.on("session_shutdown", async () => {
    if (session) {
      cleanupSession(session);
      session = null;
    }
    sessionStartCtx = null;
  });

  process.on("exit", () => {
    if (session) {
      cleanupSession(session);
    }
  });

  // ---- Tool interception for edit/write ----
  const pendingToolCalls = new Map<string, { tabId: number; toolName: string; args: any }>();

  pi.on("tool_call", async (event: ToolCallEvent, ctx: ExtensionContext) => {
    const { toolName, toolCallId, input: args } = event;
    if ((toolName === "edit" || toolName === "write") && toolCallId && session) {
      // Use the tabId from the prompt that initiated this turn
      const promptTabId = (globalThis as any).__pi_nvim_last_prompt_tabId;
      let tabId: number | null = null;
      if (promptTabId !== undefined) {
        tabId = promptTabId;
      } else {
        // Fallback: find tab by cwd
        const argsRecord = args as Record<string, unknown>;
        const filePath =
          (argsRecord.path as string) ||
          (argsRecord.file_path as string) ||
          (argsRecord.filePath as string);
        if (filePath) {
          const absPath = path.isAbsolute(filePath) ? filePath : path.join(ctx.cwd, filePath);
          if (absPath.startsWith(session.cwd)) {
            // Find a connection for this cwd (any tab)
            for (const [, tc] of session.connections) {
              if (tc.registered && tc.tabId > 0) {
                tabId = tc.tabId;
                break;
              }
            }
          }
        }
      }

      if (tabId !== null && tabId > 0) {
        pendingToolCalls.set(toolCallId, { tabId, toolName, args });

        const argsRecord = args as Record<string, unknown>;
        const filePath =
          (argsRecord.path as string) ||
          (argsRecord.file_path as string) ||
          (argsRecord.filePath as string);
        if (filePath) {
          const absPath = path.isAbsolute(filePath) ? filePath : path.join(session.cwd, filePath);

          // Read original content from disk
          let originalContent = "";
          try {
            originalContent = fs.readFileSync(absPath, "utf-8");
          } catch {}

          // Compute proposed content
          let proposedContent = "";
          if (toolName === "write") {
            proposedContent = (argsRecord.content as string) || "";
          } else if (toolName === "edit" && Array.isArray(argsRecord.edits)) {
            proposedContent = applyEdits(
              originalContent,
              argsRecord.edits as Array<{ oldText: string; newText: string }>,
            );
          }

          const reviewId = crypto.randomUUID();
          const reviewMsg = {
            type: "diff_review",
            id: reviewId,
            path: absPath,
            proposed: proposedContent,
            original: originalContent,
            tool: toolName,
            edits: argsRecord.edits,
          };

          // Store the review promise for the response handler
          let resolveFn: (action: string, content?: string) => void;
          const reviewPromise = new Promise<{ action: string; content?: string }>((resolve) => {
            resolveFn = (action: string, content?: string) => {
              resolve({ action, content });
            };
            const timeout = setTimeout(() => {
              session!.pendingReviews.delete(reviewId);
              resolveFn!("accept");
            }, 60000);
            session!.pendingReviews.set(reviewId, { resolve: resolveFn!, timeout, tabId });
          });

          // Send the diff review to the specific tab's connection
          sendToTab(session, tabId, reviewMsg);

          // Store for potential response handling
          (globalThis as any).__pi_nvim_pending_reviews =
            (globalThis as any).__pi_nvim_pending_reviews || new Map();
          (globalThis as any).__pi_nvim_pending_reviews.set(reviewId, {
            reviewPromise,
            toolCallId,
            tabId,
          });
        }
      }
    }
  });

  pi.on("tool_result", async (event: ToolResultEvent, _ctx: ExtensionContext) => {
    const { toolCallId } = event;
    pendingToolCalls.delete(toolCallId);
  });

  // ---- Socket handling ----

  function cleanupSession(s: Session) {
    for (const [, review] of s.pendingReviews) {
      clearTimeout(review.timeout);
      review.resolve("accept");
    }
    s.pendingReviews.clear();

    for (const [conn] of s.connections) {
      conn.destroy();
    }
    s.connections.clear();

    s.server.close();

    try {
      fs.unlinkSync(s.socketPath);
    } catch {}
    try {
      fs.unlinkSync(s.markerFile);
    } catch {}
    try {
      fs.unlinkSync(s.markerFile + ".info");
    } catch {}
    if (LATEST_LINK) {
      try {
        const target = fs.readlinkSync(LATEST_LINK);
        if (target === s.socketPath) fs.unlinkSync(LATEST_LINK);
      } catch {}
    }
  }

  function handleMessage(raw: string, conn: net.Socket) {
    let msg: any;
    try {
      msg = JSON.parse(raw);

      if (msg.type === "ping") {
        respond(conn, { ok: true, type: "pong" }, msg.request_id);
        return;
      }

      if (msg.type === "register_tab" && typeof msg.tabId === "number") {
        const tabId = msg.tabId;
        // Unregister any existing connection from the SAME nvim instance with
        // this tabId (stale socket from a plugin reload / reconnect). tabId is
        // only unique per nvim instance, so dedupe on (nvimPid, tabId) — never
        // across different Neovim processes.
        const nvimPid = typeof msg.nvimPid === "number" ? msg.nvimPid : null;
        for (const [existingConn, tc] of session!.connections) {
          if (existingConn !== conn && tc.registered && tc.tabId === tabId) {
            if (nvimPid !== null && tc.nvimPid === nvimPid) {
              tc.registered = false;
              tc.tabId = -1;
            }
          }
        }
        const tc = session!.connections.get(conn);
        if (tc) {
          tc.tabId = tabId;
          tc.registered = true;
          if (nvimPid !== null) tc.nvimPid = nvimPid;
          if (typeof msg.cwd === "string") tc.cwd = msg.cwd;
        }
        respond(conn, { ok: true, tabId }, msg.request_id);
        return;
      }

      if (msg.type === "prompt" && typeof msg.message === "string") {
        process.stdout.write("\x1b[?1049h\x1b[?1049l");

        // Parse metadata prefix if present: [pi-nvim-meta] {...}\n<message>
        let promptMessage = msg.message;
        let promptTabId: number | null = null;
        const metaMatch = msg.message.match(/^\[pi-nvim-meta\]\s*(\{.*\})\n([\s\S]*)$/);
        if (metaMatch) {
          try {
            const meta = JSON.parse(metaMatch[1]);
            promptMessage = metaMatch[2];
            if (typeof meta.tabId === "number") {
              promptTabId = meta.tabId;
            }
          } catch {}
        }

        // Store the tabId for this conversation turn (for tool interception)
        if (promptTabId !== null) {
          (globalThis as any).__pi_nvim_last_prompt_tabId = promptTabId;
        }

        if (sessionStartCtx) {
          try {
            pi.sendUserMessage(promptMessage, { deliverAs: "followUp" });
          } catch (e: any) {
            // If agent is busy, try steer for mid-turn queuing
            if (e.message?.includes("already processing")) {
              try {
                pi.sendUserMessage(promptMessage, { deliverAs: "steer" });
              } catch {
                respond(
                  conn,
                  { ok: false, error: "Agent is busy. Please wait for current turn to complete." },
                  msg.request_id,
                );
                return;
              }
            } else {
              throw e;
            }
          }
        }
        respond(conn, { ok: true }, msg.request_id);
        return;
      }

      if (msg.type === "diff_review_response" && typeof msg.id === "string") {
        const review = session!.pendingReviews.get(msg.id);
        if (review) {
          clearTimeout(review.timeout);
          session!.pendingReviews.delete(msg.id);
          const action =
            msg.action === "reject" ? "reject" : msg.action === "modify" ? "modify" : "accept";
          review.resolve(action, msg.content);
        }
        const globalPending = (globalThis as any).__pi_nvim_pending_reviews;
        if (globalPending && globalPending.has(msg.id)) {
          const { reviewPromise: _reviewPromise } = globalPending.get(msg.id);
          globalPending.delete(msg.id);
        }
        respond(conn, { ok: true }, msg.request_id);
        return;
      }

      respond(conn, { ok: false, error: `Unknown command type: ${msg.type}` }, msg.request_id);
    } catch (e: any) {
      respond(conn, { ok: false, error: `Parse error: ${e.message}` }, msg.request_id);
    }
  }

  function respond(conn: net.Socket, obj: any, requestId?: string) {
    try {
      if (requestId) {
        obj = Object.assign({}, obj, { request_id: requestId });
      }
      conn.write(JSON.stringify(obj) + "\n");
    } catch {}
  }

  function sendToTab(s: Session, tabId: number, msg: object) {
    const payload = JSON.stringify(msg) + "\n";
    for (const [conn, tc] of s.connections) {
      if (tc.registered && tc.tabId === tabId) {
        try {
          conn.write(payload);
          return;
        } catch {}
      }
    }
    // Fallback: broadcast to all registered connections if specific tab not found
    for (const [conn, tc] of s.connections) {
      if (tc.registered) {
        try {
          conn.write(payload);
        } catch {}
      }
    }
  }

  // Public API for tool interception
  async function requestDiffReview(
    tabId: number,
    review: {
      id: string;
      path: string;
      proposed: string;
      original: string;
      tool: "edit" | "write";
      edits?: any[];
    },
  ): Promise<{ action: string; content?: string }> {
    if (!session) {
      return { action: "accept" };
    }
    const sess = session;

    return new Promise((resolve) => {
      let resolveFn: (action: string, content?: string) => void;
      const timeout = setTimeout(() => {
        sess.pendingReviews.delete(review.id);
        resolveFn!("accept");
      }, 60000);
      resolveFn = (action: string, content?: string) => {
        resolve({ action, content });
      };
      sess.pendingReviews.set(review.id, { resolve: resolveFn, timeout, tabId });
      sendToTab(sess, tabId, { type: "diff_review", ...review });
    });
  }

  (globalThis as any).__pi_nvim_requestDiffReview = requestDiffReview;

  pi.registerCommand("pi-nvim-info", {
    description: "Show pi-nvim socket paths for all tabs",
    handler: async (_args, ctx) => {
      if (!session || session.connections.size === 0) {
        ctx.ui.notify("pi-nvim not active", "warning");
        return;
      }
      const s = session;
      const tabs = Array.from(s.connections.values())
        .filter((tc) => tc.registered)
        .map((tc) => {
          // Flag connections from a directory outside this pi session's cwd tree
          let tag = "";
          if (tc.cwd) {
            const rel = path.relative(s.cwd, tc.cwd);
            const inside = rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
            if (!inside) tag = " (cwd mismatch)";
          }
          const pidTag = tc.nvimPid !== undefined ? ` nvim[${tc.nvimPid}]` : "";
          return `Tab ${tc.tabId}${pidTag}: connected${tag}`;
        });
      if (tabs.length === 0) {
        ctx.ui.notify("pi-nvim active but no tabs registered", "info");
        return;
      }
      ctx.ui.notify(tabs.join("\n"), "info");
    },
  });

  // Helper functions for edit tool
  function applyEdits(content: string, edits: Array<{ oldText: string; newText: string }>): string {
    let result = content;
    for (const edit of edits) {
      const idx = result.indexOf(edit.oldText);
      if (idx >= 0) {
        result = result.slice(0, idx) + edit.newText + result.slice(idx + edit.oldText.length);
      }
    }
    return result;
  }

  function _computeEdits(
    original: string,
    modified: string,
  ): Array<{ oldText: string; newText: string }> {
    if (original === modified) return [];
    return [{ oldText: original, newText: modified }];
  }
}
