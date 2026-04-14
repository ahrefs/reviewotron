#!/usr/bin/env bash
# security-pipeline.sh — Ralph loop for the Security Review Pipeline PRD
# Usage: ./ralph/security-pipeline.sh
#
# Loops until all tasks in security-pipeline-tasks.json are complete.
# Each iteration picks one ready task (dependencies met, not complete),
# executes it via Claude, then advances.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TASKS_FILE="$SCRIPT_DIR/security-pipeline-tasks.json"
PROGRESS_FILE="$SCRIPT_DIR/security-pipeline-progress.txt"

touch "$PROGRESS_FILE"

echo "=== Security Review Pipeline — Ralph Loop ==="
echo "Running until all tasks complete."
echo ""

MAX_RETRIES=3
i=0
retries=0

# Helper: read tasks JSON and find the next ready task
# A task is ready if: not complete AND all depends_on tasks are complete
find_next_task() {
  python3 -c "
import json, sys

with open('$TASKS_FILE') as f:
    data = json.load(f)

tasks = data['tasks']
complete_ids = {t['id'] for t in tasks if t['complete']}

for t in tasks:
    if t['complete']:
        continue
    deps = set(t.get('depends_on', []))
    if deps <= complete_ids:
        print(json.dumps(t))
        sys.exit(0)

# No ready task found — check if all complete
if all(t['complete'] for t in tasks):
    print('ALL_COMPLETE')
else:
    print('BLOCKED')
"
}

# Helper: mark a task as complete in the JSON file
mark_complete() {
  local task_id="$1"
  python3 -c "
import json

with open('$TASKS_FILE') as f:
    data = json.load(f)

for t in data['tasks']:
    if t['id'] == '$task_id':
        t['complete'] = True
        break

with open('$TASKS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
}

# Helper: get summary stats
get_stats() {
  python3 -c "
import json

with open('$TASKS_FILE') as f:
    data = json.load(f)

tasks = data['tasks']
total = len(tasks)
done = sum(1 for t in tasks if t['complete'])
print(f'{done}/{total} tasks complete')
"
}

while true; do
  (( i++ )) || true
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "ITERATION $i — $(date '+%Y-%m-%d %H:%M:%S')"
  get_stats
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  NEXT_TASK=$(find_next_task)

  if [[ "$NEXT_TASK" == "ALL_COMPLETE" ]]; then
    echo ""
    echo "════════════════════════════════════════"
    echo "  ALL TASKS COMPLETE — Security pipeline implemented!"
    echo "════════════════════════════════════════"
    exit 0
  fi

  if [[ "$NEXT_TASK" == "BLOCKED" ]]; then
    echo "ERROR: No ready tasks found but not all tasks are complete."
    echo "This means there is a dependency cycle or a task was skipped."
    echo "Check $TASKS_FILE for issues."
    exit 1
  fi

  TASK_ID=$(echo "$NEXT_TASK" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  TASK_TITLE=$(echo "$NEXT_TASK" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")
  TASK_DESC=$(echo "$NEXT_TASK" | python3 -c "import json,sys; print(json.load(sys.stdin)['description'])")
  TASK_STEPS=$(echo "$NEXT_TASK" | python3 -c "import json,sys; print('\n'.join(f'  {i+1}. {s}' for i,s in enumerate(json.load(sys.stdin)['steps'])))")

  echo ""
  echo "▶ Task $TASK_ID: $TASK_TITLE"
  echo ""

  # Pass last 80 lines of progress for context
  PROGRESS_TAIL=$(tail -80 "$PROGRESS_FILE" 2>/dev/null || echo "(no progress yet)")

  result=$(claude -p --dangerously-skip-permissions \
"@docs/plans/2026-04-14-security-review-pipeline-prd.md
@AGENTS.md

## PROGRESS FROM PREVIOUS ITERATIONS (last 80 lines)
${PROGRESS_TAIL}

---

You are executing the RALPH LOOP for the Reviewotron Security Review Pipeline.
The codebase is an OCaml project rooted at the current directory.

## TOOLING MANDATES

You MUST use these tools for their designated purposes — no exceptions:

- **Serena MCP** (oraios/serena): Use for ALL code reading and editing. Use \`get_symbols_overview\`, \`find_symbol\`, \`find_referencing_symbols\` to explore code semantically. Use \`replace_symbol_body\`, \`insert_after_symbol\`, \`insert_before_symbol\` to edit. Do NOT read entire files when symbol-level tools suffice.
- **Context7 MCP**: Use for ALL third-party library documentation. Before using any API from ocaml-ai-sdk, melange-json-native, ppx_deriving_jsonschema, or any other dependency, query Context7 first (\`resolve-library-id\` then \`query-docs\`). Never rely on memory for library APIs.
- **Sequential Thinking MCP** (mcp__sequential-thinking__sequentialthinking): Use for ALL non-trivial decisions. Before choosing between approaches, designing module structure, or making architectural tradeoffs, work through the decision with sequential thinking.

## YOUR CURRENT TASK

**Task ID:** ${TASK_ID}
**Title:** ${TASK_TITLE}
**Description:** ${TASK_DESC}

**Steps:**
${TASK_STEPS}

## IMPLEMENTATION RULES

Follow the code style guidelines in AGENTS.md exactly. Key rules:
- No \`else if\` — use pattern matching
- Option/Result combinators over verbose matching
- Labeled arguments for >2 params
- \`[@@deriving json]\` via melange-json-native, \`[@@deriving jsonschema]\` via ppx_deriving_jsonschema
- No manual JSON manipulation
- Abstract \`type t\` pattern with .mli files
- Higher-order functions over manual recursion
- No catch-all patterns on variants
- Type-specific comparison (String.equal, not polymorphic =)
- Avoid unsafe functions (List.hd, Option.get)
- Keep functions under ~50 lines

## STEP 1: READ BEFORE CODE

Use Serena's semantic tools (\`get_symbols_overview\`, \`find_symbol\`) to understand existing code relevant to this task.
Query Context7 MCP for any third-party library APIs you need.

## STEP 2: PLAN

Use Sequential Thinking to reason through the implementation approach.
Consider tradeoffs, alternatives, and potential issues before committing to a plan.

## STEP 3: IMPLEMENT

Write the code. Follow the implementation rules above strictly.
Use Serena to work on the code while implementing, use context7 to look up library APIs. Dont make up stuff.
Make small, focused changes — one logical step at a time.

## STEP 4: REVIEW (SPAWN SUBAGENT)

After implementing, spawn a review subagent using the Agent tool with subagent_type=\"superpowers:code-reviewer\".
Give it the list of files you changed and ask it to review against AGENTS.md code style and the current task requirements.

Fix the issues identified by the review subagent.

## STEP 5: SIMPLIFY

After the review passes, invoke the /simplify skill on the changed files.
Fix any issues it identifies.

## STEP 6: QUALITY GATES

Run this command and fix any failures before proceeding: make clean build test fmt

If any gate fails, fix and re-run until all pass. This is non-negotiable.

## STEP 7: REPORT

Do NOT commit — the outer loop handles git commits after you finish.
Output the result in this exact format:

<task-result>
TASK_ID: ${TASK_ID}
STATUS: DONE
FILES_CHANGED: (list files)
DECISIONS: (key decisions made)
NOTES: (anything the next iteration should know)
</task-result>

If you cannot complete the task, output:

<task-result>
TASK_ID: ${TASK_ID}
STATUS: FAILED
REASON: (what went wrong)
NOTES: (what the next iteration should try)
</task-result>

IMPORTANT:
- ONLY WORK ON THIS SINGLE TASK
- Quality over speed — follow every rule in AGENTS.md
- If this task feels too large, break it into smaller steps but still complete them all in this iteration
- Do NOT skip the review, simplify, or quality gate steps
" 2>&1) || true

  echo "$result"

  # Check if the task was completed successfully
  if echo "$result" | grep -q "STATUS: DONE"; then

    # Commit all changes from this task
    echo ""
    echo "Committing changes for $TASK_ID..."
    cd "$PROJECT_DIR"
    git add -A
    if git diff --cached --quiet; then
      echo "(no file changes to commit)"
    else
      git commit -m "[$TASK_ID] $TASK_TITLE" || true
    fi

    mark_complete "$TASK_ID"
    echo "✓ Task $TASK_ID marked complete"

    # Extract the task-result block for progress log
    TASK_RESULT=$(echo "$result" | sed -n '/<task-result>/,/<\/task-result>/p' | head -20)

    # Log progress with implementation details for next iterations
    {
      echo "=== $TASK_ID: $TASK_TITLE ==="
      echo "Completed: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "$TASK_RESULT"
      echo ""
    } >> "$PROGRESS_FILE"

    retries=0

  elif echo "$result" | grep -q "STATUS: FAILED"; then
    echo ""
    echo "✗ Task $TASK_ID failed"

    # Log failure
    {
      echo "--- Iteration $i: $TASK_ID — FAILED ---"
      echo "Failed at $(date '+%Y-%m-%d %H:%M:%S')"
      echo "$result" | sed -n '/<task-result>/,/<\/task-result>/p' | head -20
      echo ""
    } >> "$PROGRESS_FILE"

    (( retries++ )) || true
    if [[ $retries -ge $MAX_RETRIES ]]; then
      echo "✗ Task $TASK_ID failed $MAX_RETRIES times. Backing off for 5 minutes..."
      retries=0
      sleep 300
    else
      echo "  Retrying task $TASK_ID (attempt $((retries + 1))/$MAX_RETRIES)..."
      sleep 30
    fi

  else
    # No clear status — treat as failure
    (( retries++ )) || true
    echo "⚠ Iteration $i produced no clear task result (retry $retries/$MAX_RETRIES)"

    {
      echo "--- Iteration $i: $TASK_ID — UNCLEAR RESULT ---"
      date '+%Y-%m-%d %H:%M:%S'
      echo ""
    } >> "$PROGRESS_FILE"

    if [[ $retries -ge $MAX_RETRIES ]]; then
      echo "✗ Max retries reached for $TASK_ID. Backing off for 5 minutes..."
      retries=0
      sleep 300
    else
      echo "  Retrying in 30 seconds..."
      sleep 30
    fi
  fi
done
