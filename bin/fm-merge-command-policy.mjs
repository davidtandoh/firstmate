#!/usr/bin/env node
// Raw GitHub PR merge policy. The existing arm PreToolUse transport scopes this
// policy to primary and secondmate homes and renders its deny result.
// Reuse the shell parser; never execute commands or open referenced scripts.
// This catches ordinary agent mistakes, not arbitrary programmatic evasion.
import {
  Lexer, splitProgram, commandPosition, shellInvocation,
  shellHeredocPayloads, shellHereStringPayloads, evalPayload,
} from "./fm-arm-command-policy.mjs";

const basename = (value) => value.split("/").at(-1);

function rawMerge(position) {
  if (!["gh", "gh-axi"].includes(basename(position.command?.value || ""))) return false;
  const args = position.words.slice(position.index + 1).map((word) => word.value);
  // Global selectors can precede the subcommand. Do not mistake their values
  // for commands, or quoted command examples in other subcommands for merges.
  let index = 0;
  while (args[index]?.startsWith("-")) {
    const flag = args[index++];
    if (["-R", "--repo", "--hostname"].includes(flag)) index += 1;
  }
  if (args[index] === "pr") {
    if (args[index + 1] !== "merge") return false;
    return !(args.length === index + 3 && args[index + 2] === "--help");
  }
  if (args[index] !== "api") return false;

  let method = "GET";
  let explicitMethod = false;
  let hasBody = false;
  let mergeEndpoint = false;
  const valuedFlags = new Set([
    "-X", "--method", "-f", "--raw-field", "-F", "--field", "--input",
    "-H", "--header", "--hostname", "--jq", "-q", "--template", "-t", "--cache",
  ]);
  for (let i = index + 1; i < args.length; i += 1) {
    const arg = args[i];
    const equals = arg.indexOf("=");
    const flag = equals < 0 ? arg : arg.slice(0, equals);
    if (valuedFlags.has(flag)) {
      const value = equals < 0 ? args[++i] : arg.slice(equals + 1);
      if (flag === "-X" || flag === "--method") {
        method = (value || "").toUpperCase();
        explicitMethod = true;
      }
      if (["-f", "--raw-field", "-F", "--field", "--input"].includes(flag)) hasBody = true;
      continue;
    }
    if (/^-X.+/.test(arg)) {
      method = arg.slice(2).toUpperCase();
      explicitMethod = true;
    } else if (/^-[fF].+/.test(arg)) {
      hasBody = true;
    } else if (!arg.startsWith("-") && /(?:^|\/)repos\/[^/]+\/[^/]+\/pulls\/[^/]+\/merge\/?(?:\?.*)?$/.test(arg)) {
      mergeEndpoint = true;
    }
  }
  if (hasBody && !explicitMethod) method = "POST";
  return mergeEndpoint && !["GET", "HEAD", "OPTIONS"].includes(method);
}

function containsMerge(command, depth = 0) {
  if (depth > 12) return false;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return false;
  for (const node of splitProgram(lexed.tokens).nodes) {
    for (const token of node) {
      if (token.type === "group" && containsMerge(token.content, depth + 1)) return true;
      for (const sub of token.subs || []) {
        if (containsMerge(sub.content, depth + 1)) return true;
      }
    }
    const position = commandPosition(node);
    if (rawMerge(position)) return true;
    const shell = shellInvocation(position);
    for (const payload of shell?.kind === "command" ? [shell.payload] : []) {
      if (payload?.literal && containsMerge(payload.value, depth + 1)) return true;
    }
    for (const payload of [
      ...position.wrapperPayloads,
      evalPayload(position) || "",
      ...shellHeredocPayloads(node, position),
      ...shellHereStringPayloads(node, position),
    ]) {
      if (containsMerge(payload, depth + 1)) return true;
    }
  }
  return false;
}

// CLI used only by the shared transport; input is inert shell text.
if (process.argv[2] !== "--command" || process.argv.length !== 4) {
  process.stderr.write("Usage: fm-merge-command-policy.mjs --command <command>\n");
  process.exitCode = 1;
} else if (containsMerge(process.argv[3])) {
  process.stdout.write("deny\traw-pr-merge\traw GitHub PR merges bypass Firstmate's merge checks and task metadata; use bin/fm-pr-merge.sh instead.\n");
} else {
  process.stdout.write("allow\n");
}
