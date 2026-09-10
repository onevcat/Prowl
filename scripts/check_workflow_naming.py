#!/usr/bin/env python3
"""Reject retired workflow vocabulary in maintained source and documentation."""

from pathlib import Path
import json
import re
import subprocess
import sys


RULES = (
    (r"\bWorkflowMessageContent\b", "Use a single prompt string."),
    (r"\binstruction_path\b", "Use prompt_path."),
    (r"^\s*(?:-\s*)?instruction\s*:", "Use prompt for agent task content."),
    (r"\bworkflow\s+done\b", "Use workflow deliver."),
    (r"\bWorkflowDone\w*\b", "Use WorkflowDeliver types."),
    (r"builtin:(?:git\.context|worktree\.context|agent\.context)\b", "Use a verb-first action ID."),
    (r"(?<![\w.])context\.(?:source|execution)\b", "Use context.initiator or context.action."),
    (r"(?<![\w.])context\.run\.(?:workflow_id|directory)\b", "Separate workflow metadata from run identity/path."),
    (r"(?<![\w.])context\.roles\.[\w<>-]+\.(?:name|pane)\b", "Use display_name and pane_id."),
    (r"(?<![\w.])context\.action\.(?:id|cwd|artifact_dir)\b", "Use explicit action attempt fields."),
    (r"(?<![\w.])actions\.[\w<>-]+\.result_path\b|(?<![\w.])max_rounds_reached\b", "Use output_path and iteration_limit_reached."),
    (r"(?<![\w.])backend\.environment\b", "Use backend.inherit_env."),
    (r"(?<![\w.])expect\.(?:output|verdict)\b", "Use expect.delivery and expect.verdicts."),
    (r"(?<![\w.])outputs\.[a-zA-Z_]", "Use deliveries for agent submissions."),
    (r"^\s*(?:-\s*)?expect:\s*\{[^}\n]*\b(?:output|verdict)\s*:", "Use delivery and verdicts in expect."),
    (r"^\s*(?:-\s*)?backend:\s*\{[^}\n]*\benvironment\s*:", "Use inherit_env in backend."),
    (r"\bworkflow\s+[^`\n]*\|done\b", "Use deliver in command summaries."),
    (r"`done\s+(?:-|--json)", "Use deliver in completion recipes."),
)
ROOTS = ("supacode/", "ProwlCLI/", "ProwlCLIContracts/", "Resources/workflows/", "docs/", "skills/")
REFERENCES = (
    "docs-ai/063-agent-workflows/000-plan.md",
    "docs-ai/063-agent-workflows/dsl-spec.md",
    "docs-ai/063-agent-workflows/release-plan.md",
    "docs-ai/013-prowl-cli/contracts/workflow.md",
)


def violations(text: str, *, swift: bool = False) -> list[tuple[int, str]]:
    findings = []
    try:
        structured_json = isinstance(json.loads(text), (dict, list))
    except (ValueError, TypeError):
        structured_json = False
    if re.search(r"\bworkflow\s+done\b", text):
        findings.append((1, "Use workflow deliver."))
    block = None
    block_indent = 0
    custom_indent = None
    for number, line in enumerate(text.splitlines(), 1):
        indent = len(line) - len(line.lstrip())
        if custom_indent is not None and line.strip() and indent <= custom_indent:
            custom_indent = None
        # Custom action inputs and schemas are not workflow declarations.
        yaml_line = re.sub(r"""['"]([a-z_]+)['"]\s*:""", r"\1:", line)
        custom_opener = re.match(r"\s*(?:-\s*)?(?P<key>with|input_schema|output_schema):", yaml_line)
        custom_data = custom_indent is not None or custom_opener is not None
        if custom_opener and custom_indent is None:
            custom_indent = custom_opener.start("key")
        # Swift property names are internal implementation, not expression namespaces.
        public_text = line
        if swift:
            public_text = " ".join(re.findall(r'"([^"\n]*)"', line))
            if line.lstrip().startswith("//"):
                public_text = line
        for pattern, message in RULES:
            if pattern == r"\binstruction_path\b" and (custom_data or structured_json):
                continue
            if pattern.startswith(r"^\s*(?:-\s*)?"):
                if custom_data:
                    continue
                candidate = yaml_line
            else:
                candidate = line if pattern.startswith((r"\bWorkflowDone", r"\bWorkflowMessageContent")) else public_text
            candidate = candidate.replace("\\", "")
            candidate = re.sub(r"""\[\s*['"]([a-zA-Z_][\w-]*)['"]\s*\]""", r".\1", candidate)
            candidate = re.sub(
                r"{{(.*?)}}",
                lambda match: re.sub(r"\s*\.\s*", ".", match[0]),
                candidate,
            )
            if re.search(pattern, candidate):
                findings.append((number, message))
        if block and line.strip() and indent <= block_indent:
            block = None
        if block and not custom_data and re.match(r"\s*(?:output|verdict):" if block == "expect" else r"\s*environment:", yaml_line):
            findings.append((number, "Use the current expect/backend declaration keys."))
        match = None if custom_data else re.match(r"\s*(expect|backend):\s*(?:#.*)?$", yaml_line)
        if match:
            block, block_indent = match[1], indent
    if not swift:
        candidates = [text] + re.findall(r"```json\s*\n(.*?)```", text, re.DOTALL)
        for candidate in candidates:
            try:
                value = json.loads(candidate)
            except (ValueError, TypeError):
                continue
            def check_declarations(node):
                if isinstance(node, list):
                    for item in node:
                        check_declarations(item)
                elif isinstance(node, dict):
                    if node.get("command") == "workflow":
                        check_declarations(node.get("data"))
                    task = node.get("self_initiated")
                    if isinstance(task, dict) and "instruction_path" in task:
                        findings.append((1, "Use prompt_path."))
                    if "message" in node and set(node) & {"text", "instruction"}:
                        findings.append((1, "Use prompt for agent task content."))
                    expect = node.get("expect")
                    if isinstance(expect, dict) and set(expect) & {"output", "verdict"}:
                        findings.append((1, "Use delivery and verdicts in expect."))
                    backend = node.get("backend")
                    if isinstance(backend, dict) and backend.get("type") == "script" and "environment" in backend:
                        findings.append((1, "Use inherit_env in script backend."))
                    # Descend only through workflow control-flow containers, never custom action data.
                    for key in ("steps", "body", "then", "else"):
                        if key in node:
                            check_declarations(node[key])

            check_declarations(value)
            if (isinstance(value, dict) and value.get("protocol") == "prowl.action/v1"
                    and isinstance(value.get("context"), dict)):
                context = value["context"]
                invalid = set(context) & {"source", "execution"}
                run = context.get("run", {})
                action = context.get("action", {})
                if isinstance(run, dict):
                    invalid |= set(run) & {"workflow_id", "directory"}
                if isinstance(action, dict):
                    invalid |= set(action) & {"id", "cwd", "artifact_dir"}
                roles = context.get("roles", {})
                if isinstance(roles, dict):
                    for role in roles.values():
                        if isinstance(role, dict):
                            invalid |= set(role) & {"name", "pane"}
                if invalid:
                    findings.append((1, "Retired context JSON keys: " + ", ".join(sorted(invalid))))
    return findings


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=root, text=True)
    errors = []
    for name in sorted(set(names.splitlines())):
        if not (name.startswith(ROOTS + ("docs-ai/063-agent-workflows/",)) or name in REFERENCES):
            continue
        path = root / name
        if path.is_symlink() or not path.is_file() or path.suffix not in {".swift", ".md", ".json", ".yaml", ".yml"}:
            continue
        text = path.read_text()
        # The naming decision records old-to-new mappings; historical slices are explicitly marked.
        if name.endswith("019-workflow-naming.md") or text.startswith("> Historical slice record."):
            continue
        errors.extend(f"{name}:{line}: {message}" for line, message in violations(text, swift=path.suffix == ".swift"))
    for error in errors:
        print(error)
    if not errors:
        print("Workflow naming checks passed.")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
