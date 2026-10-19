import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { diskFs } from "./extract-asar.js";

// Keep handoff synchronous for existing callers. The controller owns shutdown, never the Host.
export function restartWindowsDesktop({ exe, asar, home = "", commit = true }) {
  const fs = diskFs();
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-purge-restart-"));
  const log = path.join(workDir, "restart.log");
  const request = path.join(workDir, "request.json");
  fs.writeFileSync(request, JSON.stringify({ exe, asar, home }), "utf8");
  const script = fileURLToPath(new URL("./restart-windows.ps1", import.meta.url));
  const shell = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  try {
    const output = execFileSync(shell, [
      "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
      "-RequestPath", request, "-Launch",
    ], { encoding: "utf8", windowsHide: true, timeout: 20000, stdio: ["ignore", "pipe", "pipe"] });
    const state = JSON.parse(output.trim().replace(/^\uFEFF/, ""));
    if (state.phase !== "ready") throw new Error("Controller did not confirm readiness");
    fs.writeFileSync(path.join(workDir, commit ? "commit" : "cancel"), "", "utf8");
    return { restarting: commit, prepared: true, controllerPid: state.pid, engine: "controller", log };
  } catch (error) {
    fs.writeFileSync(path.join(workDir, "cancel"), "", "utf8");
    const detail = error.stderr?.toString().trim() || error.message || String(error);
    return { restarting: false, error: `桌面重启交接失败: ${detail}`, log };
  }
}
