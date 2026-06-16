export function reviewCommandRequest() {
  return {
    mode: "worktree_diff",
    profile: "quick",
    title: "Pi quick review",
  };
}

export function fullCommandRequest(args = "") {
  const path = args.trim() || ".";
  return {
    mode: "path",
    profile: "full",
    path,
    title: path === "." ? "Pi full project review" : `Pi full review for ${path}`,
  };
}

export function configHelpRequest() {
  return {
    mode: "config_help",
    timeoutMs: 30000,
  };
}

export function requestFromToolParams(params = {}) {
  const mode = params.mode ?? (params.path ? "path" : params.diff ? "stdin_diff" : "worktree_diff");
  const profile = params.profile ?? "quick";
  return {
    mode,
    profile,
    path: params.path,
    diff: params.diff,
    root: params.root,
    base: params.base,
    title: params.title,
    changeKey: params.changeKey,
    statePath: params.statePath,
    config: params.config,
    security: params.security,
    timeoutMs: params.timeoutMs,
  };
}
