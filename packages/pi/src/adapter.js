import { spawn } from "node:child_process";
import { stat } from "node:fs/promises";
import { delimiter, isAbsolute, join } from "node:path";

export const DEFAULT_REVIEWOTRON_BIN = "reviewotron";
export const DEFAULT_QUICK_TIMEOUT_MS = 5 * 60 * 1000;
export const DEFAULT_FULL_TIMEOUT_MS = 15 * 60 * 1000;
export const FULL_REVIEW_CONFIG = Object.freeze({
  max_files: 500,
  max_diff_lines: 50000,
});

const LOCAL_PATH_PREFIX = "@";
const configSchemaCache = new Map();

export function resolveReviewotronBin(env = process.env) {
  const configured = env.REVIEWOTRON_BIN?.trim();
  return configured && configured.length > 0 ? configured : DEFAULT_REVIEWOTRON_BIN;
}

export function normalizePathArgument(path) {
  return path.startsWith(LOCAL_PATH_PREFIX) ? path.slice(LOCAL_PATH_PREFIX.length) : path;
}

export function configToCliValue(config) {
  return typeof config === "string" ? config : JSON.stringify(config);
}

function shouldDisableSecurity(request) {
  if (typeof request.noSecurity === "boolean") {
    return request.noSecurity;
  }

  if (typeof request.security === "boolean") {
    return !request.security;
  }

  return request.profile !== "full";
}

function schemaProperties(configSchema) {
  const properties = configSchema?.properties;
  return properties && typeof properties === "object" ? properties : null;
}

export function fullReviewConfigForSchema(configSchema) {
  const properties = schemaProperties(configSchema);
  if (!properties) {
    return FULL_REVIEW_CONFIG;
  }

  const config = {};
  if (Object.hasOwn(properties, "max_files")) {
    config.max_files = FULL_REVIEW_CONFIG.max_files;
  }
  if (Object.hasOwn(properties, "max_diff_lines")) {
    config.max_diff_lines = FULL_REVIEW_CONFIG.max_diff_lines;
  }

  return Object.keys(config).length > 0 ? config : undefined;
}

function defaultConfigFor(request, configSchema) {
  if (request.config !== undefined) {
    return request.config;
  }

  return request.profile === "full" ? fullReviewConfigForSchema(configSchema) : undefined;
}

function timeoutFor(request) {
  if (Number.isFinite(request.timeoutMs) && request.timeoutMs > 0) {
    return request.timeoutMs;
  }

  return request.profile === "full" ? DEFAULT_FULL_TIMEOUT_MS : DEFAULT_QUICK_TIMEOUT_MS;
}

function pushOption(args, flag, value) {
  if (value !== undefined && value !== null && `${value}`.length > 0) {
    args.push(flag, `${value}`);
  }
}

function pushCommonReviewOptions(args, request, configSchema) {
  pushOption(args, "--repo-key", request.repoKey);
  pushOption(args, "--change-key", request.changeKey);
  pushOption(args, "--title", request.title);
  pushOption(args, "--state", request.statePath);

  const config = defaultConfigFor(request, configSchema);
  if (config !== undefined) {
    args.push("--config", configToCliValue(config));
  }

  if (shouldDisableSecurity(request)) {
    args.push("--no-security");
  }

  args.push("--output", "json");
}

function requireValue(value, message) {
  if (typeof value === "string" && value.trim().length > 0) {
    return value;
  }

  throw new Error(message);
}

export function buildReviewotronCommand(request, options = {}) {
  const env = options.env ?? process.env;
  const bin = request.bin ?? resolveReviewotronBin(env);
  const profile = request.profile ?? "quick";
  const normalizedRequest = { ...request, profile };
  const configSchema = request.configSchema ?? options.configSchema;

  switch (request.mode) {
    case "config_help":
      return {
        bin,
        args: ["config-help"],
        stdin: "",
        timeoutMs: timeoutFor({ ...normalizedRequest, timeoutMs: request.timeoutMs ?? 30000 }),
      };

    case "path": {
      const path = normalizePathArgument(requireValue(request.path, "path mode requires a path"));
      const args = ["review-path"];
      pushCommonReviewOptions(args, normalizedRequest, configSchema);
      args.push(path);
      return { bin, args, stdin: "", timeoutMs: timeoutFor(normalizedRequest) };
    }

    case "stdin_diff": {
      const diff = requireValue(request.diff, "stdin_diff mode requires a diff string");
      const args = ["review-diff"];
      pushOption(args, "--root", request.root);
      args.push("--diff", "-");
      pushCommonReviewOptions(args, normalizedRequest, configSchema);
      return { bin, args, stdin: diff, timeoutMs: timeoutFor(normalizedRequest) };
    }

    case "worktree_diff": {
      const args = ["review-diff"];
      pushOption(args, "--root", request.root);
      pushOption(args, "--base", request.base);
      pushCommonReviewOptions(args, normalizedRequest, configSchema);
      return { bin, args, stdin: "", timeoutMs: timeoutFor(normalizedRequest) };
    }

    default:
      throw new Error(`unsupported Reviewotron review mode: ${request.mode}`);
  }
}

function commandForDisplay(command) {
  return [command.bin, ...command.args].join(" ");
}

function parseJson(stdout) {
  try {
    return { ok: true, value: JSON.parse(stdout) };
  } catch (error) {
    return { ok: false, error };
  }
}

function stringOrEmpty(value) {
  return typeof value === "string" ? value : "";
}

function stringOrNull(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function normalizeFinding(finding) {
  return {
    file: stringOrEmpty(finding.file),
    line: Number.isInteger(finding.line) ? finding.line : null,
    level: stringOrEmpty(finding.level),
    category: stringOrEmpty(finding.category),
    summary: stringOrEmpty(finding.summary),
    failureScenario: stringOrEmpty(finding.failure_scenario),
    raw: finding,
  };
}

function normalizeReport(raw) {
  const findings = Array.isArray(raw.findings) ? raw.findings.map(normalizeFinding) : [];
  return {
    schemaVersion: Number.isInteger(raw.schema_version) ? raw.schema_version : 0,
    status: stringOrEmpty(raw.review_status) || "completed",
    summary: stringOrEmpty(raw.summary),
    findings,
    reviewedRoot: stringOrNull(raw.reviewed_root),
    changeKey: stringOrNull(raw.change_key),
    raw,
  };
}

function candidateExecutablePaths(bin, env) {
  if (isAbsolute(bin) || bin.includes("/")) {
    return [bin];
  }

  return (env.PATH ?? "")
    .split(delimiter)
    .filter((dir) => dir.length > 0)
    .map((dir) => join(dir, bin));
}

async function configSchemaCacheKey(bin, env) {
  const candidates = candidateExecutablePaths(bin, env);
  for (const candidate of candidates) {
    try {
      const info = await stat(candidate);
      if (info.isFile()) {
        return `${candidate}:${info.mtimeMs}:${info.size}`;
      }
    } catch {
      // Try the next PATH entry.
    }
  }

  try {
    const info = await stat(bin);
    return `${bin}:${info.mtimeMs}:${info.size}`;
  } catch {
    return `${bin}:path`;
  }
}

function resultFromProcess({ command, stdout, stderr, code, signal, timedOut }) {
  if (timedOut) {
    return {
      ok: false,
      kind: "timeout",
      error: `reviewotron timed out after ${command.timeoutMs}ms`,
      command: commandForDisplay(command),
      stdout,
      stderr,
      code,
      signal,
    };
  }

  const parsed = parseJson(stdout);
  if (!parsed.ok) {
    return {
      ok: false,
      kind: "malformed_json",
      error: `reviewotron did not return valid JSON: ${parsed.error.message}`,
      command: commandForDisplay(command),
      stdout,
      stderr,
      code,
      signal,
    };
  }

  if (typeof parsed.value.error === "string") {
    return {
      ok: false,
      kind: "reviewotron_error",
      error: parsed.value.error,
      command: commandForDisplay(command),
      stdout,
      stderr,
      code,
      signal,
      raw: parsed.value,
    };
  }

  if (code !== 0) {
    return {
      ok: false,
      kind: "process_error",
      error: `reviewotron exited with ${code}`,
      command: commandForDisplay(command),
      stdout,
      stderr,
      code,
      signal,
      raw: parsed.value,
    };
  }

  return {
    ok: true,
    command: commandForDisplay(command),
    stderr,
    code,
    report: normalizeReport(parsed.value),
  };
}

function executeCommand(command, options = {}) {
  const cwd = options.cwd ?? process.cwd();
  const env = options.env ?? process.env;
  const spawnImpl = options.spawn ?? spawn;

  return new Promise((resolve) => {
    let settled = false;
    let timedOut = false;
    let stdout = "";
    let stderr = "";

    const settle = (result) => {
      if (!settled) {
        settled = true;
        resolve(result);
      }
    };

    const child = spawnImpl(command.bin, command.args, {
      cwd,
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, command.timeoutMs);

    const abort = () => {
      timedOut = true;
      child.kill("SIGTERM");
    };

    options.signal?.addEventListener("abort", abort, { once: true });

    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      options.signal?.removeEventListener("abort", abort);
      const kind = error.code === "ENOENT" ? "missing_binary" : "spawn_error";
      settle({
        ok: false,
        kind,
        error:
          kind === "missing_binary"
            ? `reviewotron binary not found: ${command.bin}. Install reviewotron on PATH or set REVIEWOTRON_BIN.`
            : error.message,
        command: commandForDisplay(command),
        stdout,
        stderr,
        code: null,
        signal: null,
      });
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      options.signal?.removeEventListener("abort", abort);
      settle(resultFromProcess({ command, stdout, stderr, code, signal, timedOut }));
    });

    if (command.stdin.length > 0) {
      child.stdin?.write(command.stdin);
    }
    child.stdin?.end();
  });
}

export function clearConfigSchemaCache() {
  configSchemaCache.clear();
}

export async function loadConfigSchema(options = {}) {
  const env = options.env ?? process.env;
  const bin = options.bin ?? resolveReviewotronBin(env);
  const cacheKey = await configSchemaCacheKey(bin, env);
  const cached = configSchemaCache.get(cacheKey);
  if (cached) {
    return cached;
  }

  const command = buildReviewotronCommand({ mode: "config_help", bin }, options);
  const result = await executeCommand(command, options);
  const schemaResult =
    result.ok && schemaProperties(result.report.raw)
      ? { ok: true, schema: result.report.raw, command: result.command }
      : {
          ok: false,
          kind: result.ok ? "invalid_config_schema" : result.kind,
          error: result.ok
            ? "reviewotron config-help returned JSON, but it did not look like a JSON Schema object"
            : result.error,
          result,
        };

  if (schemaResult.ok) {
    configSchemaCache.set(cacheKey, schemaResult);
  }

  return schemaResult;
}

function shouldLoadConfigSchema(request) {
  const profile = request.profile ?? "quick";
  return request.mode !== "config_help" && request.config === undefined && profile === "full";
}

export async function runReviewotron(request, options = {}) {
  const env = options.env ?? process.env;
  const bin = request.bin ?? resolveReviewotronBin(env);
  let configSchema = request.configSchema ?? options.configSchema;
  let configSchemaWarning = null;

  if (configSchema === undefined && shouldLoadConfigSchema(request)) {
    const schemaResult = await loadConfigSchema({ ...options, bin });
    if (schemaResult.ok) {
      configSchema = schemaResult.schema;
    } else if (schemaResult.kind === "missing_binary") {
      return schemaResult.result;
    } else {
      configSchemaWarning = schemaResult.error;
    }
  }

  const command = buildReviewotronCommand({ ...request, bin }, { ...options, configSchema });
  const result = await executeCommand(command, options);
  if (configSchemaWarning) {
    return { ...result, configSchemaWarning };
  }

  return result;
}

function formatFinding(finding) {
  const location = finding.line === null ? finding.file : `${finding.file}:${finding.line}`;
  const prefix = [finding.level, finding.category].filter(Boolean).join("/");
  return `- ${prefix ? `[${prefix}] ` : ""}${location} ${finding.summary}`.trimEnd();
}

export function formatReviewResult(result) {
  if (!result.ok) {
    const setupHint =
      result.kind === "missing_binary"
        ? "\n\nSet REVIEWOTRON_BIN to the reviewotron binary path, or install reviewotron on PATH."
        : "";
    const stderr = result.stderr?.trim() ? `\n\nstderr:\n${result.stderr.trim()}` : "";
    return `Reviewotron failed (${result.kind}).\n\n${result.error}\n\nCommand: ${result.command}${setupHint}${stderr}`;
  }

  const report = result.report;
  const header = `Reviewotron review completed (status: ${report.status}).`;
  const configWarning = result.configSchemaWarning ? `\nConfig schema warning: ${result.configSchemaWarning}` : "";
  const root = report.reviewedRoot ? `\nReviewed root: ${report.reviewedRoot}` : "";
  const change = report.changeKey ? `\nChange key: ${report.changeKey}` : "";
  const summary = report.summary.trim() ? `\n\nSummary:\n${report.summary.trim()}` : "";
  const findings =
    report.findings.length === 0
      ? "\n\nFindings: none"
      : `\n\nFindings (${report.findings.length}):\n${report.findings.map(formatFinding).join("\n")}`;

  return `${header}${configWarning}${root}${change}${summary}${findings}`;
}

export function summarizeConfigHelp(rawSchema) {
  const properties = rawSchema?.properties;
  if (!properties || typeof properties !== "object") {
    return "Reviewotron config-help returned JSON, but it did not look like a JSON Schema object.";
  }

  const topLevel = Object.keys(properties).sort();
  const pluginProperties = properties.review_plugins?.properties ?? {};
  const generalProperties = pluginProperties.general?.properties ?? {};
  const securityProperties = pluginProperties.security?.properties ?? {};

  const lines = ["Reviewotron config fields:", ...topLevel.map((field) => `- ${field}`)];
  const general = Object.keys(generalProperties).sort();
  if (general.length > 0) {
    lines.push("", "review_plugins.general:", ...general.map((field) => `- ${field}`));
  }

  const security = Object.keys(securityProperties).sort();
  if (security.length > 0) {
    lines.push("", "review_plugins.security:", ...security.map((field) => `- ${field}`));
  }

  return lines.join("\n");
}
