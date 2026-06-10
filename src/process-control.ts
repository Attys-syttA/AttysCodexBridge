import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import type { TeleCodexConfig } from "./config.js";

export type BotControlAction = "restart" | "stop";
export type LauncherLaunchProfileId = "default" | "read-only" | "workspace-write" | "approval" | "full-access";

export interface LauncherLaunchProfile {
  id: LauncherLaunchProfileId;
  label: string;
  sandboxMode: string;
  approvalPolicy: string;
  unsafe: boolean;
}

export const LAUNCHER_LAUNCH_PROFILES: LauncherLaunchProfile[] = [
  {
    id: "default",
    label: "Default from .env",
    sandboxMode: ".env",
    approvalPolicy: ".env",
    unsafe: false,
  },
  {
    id: "read-only",
    label: "Read only",
    sandboxMode: "read-only",
    approvalPolicy: "never",
    unsafe: false,
  },
  {
    id: "workspace-write",
    label: "Workspace write",
    sandboxMode: "workspace-write",
    approvalPolicy: "never",
    unsafe: false,
  },
  {
    id: "approval",
    label: "Workspace write with approval",
    sandboxMode: "workspace-write",
    approvalPolicy: "on-request",
    unsafe: false,
  },
  {
    id: "full-access",
    label: "Full access",
    sandboxMode: "danger-full-access",
    approvalPolicy: "on-request",
    unsafe: true,
  },
];

export function findLauncherLaunchProfile(id: string): LauncherLaunchProfile | undefined {
  return LAUNCHER_LAUNCH_PROFILES.find((profile) => profile.id === id);
}

export interface BotControlRequest {
  schemaVersion: 1;
  action: BotControlAction;
  requestedAt: string;
  requestedBy?: string;
  pid: number;
  hostLabel: string;
  repoRoot: string;
  launchProfile?: LauncherLaunchProfileId;
  expiresAt?: string;
}

export const BOT_STOP_REQUEST_TTL_MS = 15 * 60 * 1000;

export async function writeBotControlRequest(
  config: TeleCodexConfig,
  action: BotControlAction,
  requestedBy?: string,
  now = new Date(),
  launchProfile?: LauncherLaunchProfileId,
): Promise<BotControlRequest> {
  const request: BotControlRequest = {
    schemaVersion: 1,
    action,
    requestedAt: now.toISOString(),
    ...(requestedBy ? { requestedBy } : {}),
    pid: process.pid,
    hostLabel: config.hostLabel,
    repoRoot: process.cwd(),
    ...(action === "restart" && launchProfile ? { launchProfile } : {}),
    ...(action === "stop" ? { expiresAt: new Date(now.getTime() + BOT_STOP_REQUEST_TTL_MS).toISOString() } : {}),
  };

  await mkdir(config.stateDir, { recursive: true });
  await writeFile(
    path.join(config.stateDir, `${action}-request.json`),
    `${JSON.stringify(request, null, 2)}\n`,
    "utf8",
  );
  return request;
}

export async function clearBotControlRequest(
  config: TeleCodexConfig,
  action: BotControlAction,
): Promise<void> {
  await rm(path.join(config.stateDir, `${action}-request.json`), { force: true });
}

export function scheduleBotRestart(
  repoRoot = process.cwd(),
  launchProfile: LauncherLaunchProfileId = "default",
): void {
  if (process.platform !== "win32") {
    throw new Error("Bot restart from Telegram is currently supported only on Windows.");
  }

  const launcherPath = path.join(repoRoot, "start-attyscodexbridge-workspace.ps1");
  if (!existsSync(launcherPath)) {
    throw new Error(`Launcher not found: ${launcherPath}`);
  }

  const command = [
    "Start-Sleep -Seconds 2",
    [
      "Start-Process",
      "-FilePath 'powershell.exe'",
      "-ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',",
      `'${escapePowerShellSingleQuoted(launcherPath)}','-LaunchProfile','${launchProfile}')`,
      `-WorkingDirectory '${escapePowerShellSingleQuoted(repoRoot)}'`,
      "-WindowStyle Hidden",
    ].join(" "),
  ].join("; ");

  const child = spawn(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
    {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    },
  );
  child.unref();
}

export function requestGracefulBotShutdown(delayMs = 250): void {
  setTimeout(() => {
    process.kill(process.pid, "SIGTERM");
  }, delayMs).unref();
}

function escapePowerShellSingleQuoted(value: string): string {
  return value.replace(/'/g, "''");
}
