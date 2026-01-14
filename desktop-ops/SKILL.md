---
name: desktop-ops
description: Operate macOS desktop UI via the desktop-ops CLI using the snapshot/ref/action workflow. Use when an agent needs to read UI state with `desktop-ops snapshot --json`, select refs, and execute `click`, `set-value`, `focus`, `press`, or `run` a recipe JSON.
---

# Desktop Ops

## Overview

Expose the current macOS UI as a JSON snapshot, then act on stable refs with single-step CLI commands. Keep logic, retries, and decisions in the agent.

## Workflow (Snapshot -> Ref -> Action)

1. Run `desktop-ops snapshot --json`.
2. Parse the tree; choose a target by `role`, `name`, `value`, `actions`, and `enabled`.
3. Use only the node `ref` for actions.
4. Re-run `snapshot` after any UI change.
5. Record the same sequence as a recipe if you need replay.

## Ref Rules

- Treat `ref` as stable only for the same UI state.
- If a command returns `NotFound` or `NotActionable`, re-snapshot and pick a new ref.
- Do not guess or synthesize refs.

## Command Reference (v1)

Snapshot:

```bash
desktop-ops snapshot --json
```

Actions:

```bash
desktop-ops click <ref>
desktop-ops set-value <ref> <text>
desktop-ops focus <ref>
desktop-ops press <key>
```

Recipe:

```bash
desktop-ops run <recipe.json>
```

## Snapshot Shape (minimum fields)

Each node includes:

```json
{
  "ref": "n12",
  "role": "AXButton",
  "name": "Save",
  "value": null,
  "enabled": true,
  "actions": ["click"],
  "children": []
}
```

Assume missing attributes are `null`.

## Recipe Format

Use a JSON array of commands. Execute sequentially; stop on first error. Include `snapshot` only when you need a fresh state.

```json
[
  { "cmd": "snapshot" },
  { "cmd": "click", "ref": "n12" },
  { "cmd": "set_value", "ref": "n15", "value": "hello" },
  { "cmd": "press", "key": "Enter" }
]
```

## Output and Errors

When `--json` is set, expect:

```json
{ "success": true, "data": { ... } }
```

On error:

```json
{ "success": false, "error": "NotFound", "message": "ref n12 not found" }
```

Handle errors in the agent; do not retry inside desktop-ops.
