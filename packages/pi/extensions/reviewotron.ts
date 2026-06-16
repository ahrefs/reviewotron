import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import {
  formatReviewResult,
  runReviewotron,
  summarizeConfigHelp,
} from "../src/adapter.js";
import {
  configHelpRequest,
  fullCommandRequest,
  requestFromToolParams,
  reviewCommandRequest,
} from "../src/extension-core.js";

async function publishReview(pi: ExtensionAPI, ctx: any, request: any, title: string) {
  ctx.ui.setStatus("reviewotron", "Reviewotron running");
  try {
    const result = await runReviewotron(request, { cwd: ctx.cwd, signal: ctx.signal });
    const content = formatReviewResult(result);
    pi.sendMessage({
      customType: "reviewotron",
      content: `${title}\n\n${content}`,
      display: true,
      details: result,
    });

    if (result.ok) {
      ctx.ui.notify("Reviewotron review complete", "info");
    } else {
      ctx.ui.notify(`Reviewotron failed: ${result.kind}`, "error");
    }
  } finally {
    ctx.ui.setStatus("reviewotron", "");
  }
}

async function publishConfigHelp(pi: ExtensionAPI, ctx: any) {
  ctx.ui.setStatus("reviewotron", "Reviewotron config-help");
  try {
    const result = await runReviewotron(configHelpRequest(), { cwd: ctx.cwd, signal: ctx.signal });
    const content = result.ok ? summarizeConfigHelp(result.report.raw) : formatReviewResult(result);
    pi.sendMessage({
      customType: "reviewotron",
      content,
      display: true,
      details: result,
    });
  } finally {
    ctx.ui.setStatus("reviewotron", "");
  }
}

export default function reviewotronExtension(pi: ExtensionAPI) {
  pi.registerTool({
    name: "reviewotron_review",
    label: "Reviewotron Review",
    description:
      "Run Reviewotron against the current git diff, a provided unified diff, or a file/directory path.",
    promptSnippet:
      "Run Reviewotron for agent-facing code review of the current diff, stdin diff, file, or directory.",
    promptGuidelines: [
      "Use reviewotron_review after meaningful code changes when an independent Reviewotron pass would catch bugs, regressions, or security issues.",
      "Use reviewotron_review with profile=quick during fix loops; use profile=full before final delivery or when the user asks for a full review.",
      "After fixing Reviewotron findings, run reviewotron_review again on the updated diff unless the user asked not to re-run checks.",
    ],
    parameters: Type.Object({
      mode: Type.Optional(StringEnum(["worktree_diff", "stdin_diff", "path"] as const)),
      profile: Type.Optional(StringEnum(["quick", "full"] as const)),
      path: Type.Optional(Type.String({ description: "File or directory path for path mode." })),
      diff: Type.Optional(Type.String({ description: "Unified diff text for stdin_diff mode." })),
      root: Type.Optional(Type.String({ description: "Repository root for diff review." })),
      base: Type.Optional(Type.String({ description: "Base ref for generated worktree diffs." })),
      title: Type.Optional(Type.String({ description: "Review title passed to Reviewotron." })),
      changeKey: Type.Optional(Type.String({ description: "Explicit Reviewotron change key." })),
      statePath: Type.Optional(Type.String({ description: "Optional Reviewotron state file path." })),
      security: Type.Optional(
        Type.Boolean({ description: "Enable security review. Defaults to false for quick and true for full." }),
      ),
      timeoutMs: Type.Optional(Type.Number({ description: "Timeout in milliseconds." })),
      config: Type.Optional(Type.Any({ description: "Inline Reviewotron JSON config object or JSON string." })),
    }),
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      onUpdate?.({ content: [{ type: "text", text: "Running Reviewotron..." }] });
      const result = await runReviewotron(requestFromToolParams(params), { cwd: ctx.cwd, signal });
      return {
        content: [{ type: "text", text: formatReviewResult(result) }],
        details: result,
      };
    },
  });

  pi.registerCommand("reviewotron", {
    description: "Run a quick Reviewotron review on the current git diff.",
    handler: async (_args, ctx) => {
      await publishReview(pi, ctx, reviewCommandRequest(), "Reviewotron quick review");
    },
  });

  pi.registerCommand("reviewotron-full", {
    description: "Run a full Reviewotron review on a path, or the current project when no path is provided.",
    handler: async (args, ctx) => {
      await publishReview(pi, ctx, fullCommandRequest(args), "Reviewotron full review");
    },
  });

  pi.registerCommand("reviewotron-config", {
    description: "Show Reviewotron config knobs from reviewotron config-help.",
    handler: async (_args, ctx) => {
      await publishConfigHelp(pi, ctx);
    },
  });
}
