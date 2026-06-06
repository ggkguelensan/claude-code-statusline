#!/usr/bin/python3
"""Claude Code status line.

[Model] | 🌿 branch* | PR#12 👀 | ctx 31% | $1.23 · +156/-23 · ⏱ 12m | 5h 23% · 7d 41%

Input: JSON on stdin (see https://code.claude.com/docs/en/statusline).
Optional segments (git, PR, rate limits) are skipped when data is absent.
"""
import json
import os
import re
import subprocess
import sys
import time

DIM, RST = "\033[2m", "\033[0m"
GRN, YLW, RED, CYN, BLD = "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[1m"
MAG = "\033[35m"
SEP = f" {DIM}|{RST} "
DOT = f" {DIM}·{RST} "

PR_ICONS = {"approved": " ✅", "changes_requested": " ❌", "draft": " 📝", "pending": " 👀"}
EFFORT_ABBR = {"low": "lo", "medium": "med", "high": "hi", "xhigh": "xh", "max": "max"}


def short_model(name):
    """'Opus 4.8 (1M context)' -> 'O 4.8 1M', 'Sonnet 4.6' -> 'S 4.6'."""
    name = re.sub(r"\((\d+[KM]) context\)", r"\1", name)
    parts = name.split()
    if parts and parts[0].isalpha():
        parts[0] = parts[0][0]
    return " ".join(parts)


def git(cwd, *args):
    try:
        out = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True, text=True, timeout=2,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def rl_color(pct):
    return RED if pct >= 90 else YLW if pct >= 70 else DIM


def repo_info(d):
    """Git facts for directory `d`, or None when it's not inside a repo."""
    out = git(d, "rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir")
    lines = out.splitlines()
    if len(lines) < 3:
        return None
    root = os.path.realpath(lines[0])
    git_dir = os.path.realpath(os.path.join(d, lines[1]))
    common_dir = os.path.realpath(os.path.join(d, lines[2]))
    branch = git(d, "branch", "--show-current") or "@" + git(d, "rev-parse", "--short", "HEAD")
    return {
        "root": root,
        "name": os.path.basename(root),
        "branch": branch,
        "is_worktree": git_dir != common_dir,  # linked worktree has .git/worktrees/<name>
        "dirty": bool(git(d, "status", "--porcelain")),
    }


data = json.load(sys.stdin)
segments = []

# --- model (+ reasoning effort when the model supports it) ---
model = data.get("model", {}).get("display_name", "?")
seg_model = f"{BLD}{CYN}{short_model(model)}{RST}"
effort = (data.get("effort") or {}).get("level")
if effort:
    seg_model += f" {MAG}⚡{EFFORT_ABBR.get(effort, effort)}{RST}"
segments.append(seg_model)

# --- git: 🌿 checkout / 🌳 worktree; multi-repo (/add-dir) as repo:branch ---
workspace = data.get("workspace") or {}
cwd = workspace.get("current_dir") or data.get("cwd") or "."
dirs = [cwd] + (workspace.get("added_dirs") or [])
repos, seen = [], set()
for d in dirs:
    info = repo_info(d)
    if info and info["root"] not in seen:
        seen.add(info["root"])
        repos.append(info)
if repos:
    multi = len(repos) > 1
    session_wt = data.get("worktree") or {}  # --worktree sessions only
    parts = []
    for i, r in enumerate(repos):
        icon = "🌳" if r["is_worktree"] else "🌿"
        prefix = f"{DIM}{r['name']}:{RST}" if multi else ""
        entry = f"{icon} {prefix}{GRN}{r['branch']}{RST}"
        if r["dirty"]:
            entry += f"{YLW}*{RST}"
        if i == 0 and r["is_worktree"] and session_wt.get("original_branch"):
            entry += f" {DIM}← {session_wt['original_branch']}{RST}"
        parts.append(entry)
    segments.append(DOT.join(parts))

# --- open PR (field disappears when PR merges/closes) ---
pr = data.get("pr") or {}
if pr.get("number"):
    icon = PR_ICONS.get(pr.get("review_state", ""), "")
    segments.append(f"PR#{pr['number']}{icon}")

# --- context ---
ctx = data.get("context_window") or {}
pct = int(ctx.get("used_percentage") or 0)
segments.append(f"ctx {pct}%")

# --- cost · +lines/-lines · duration ---
cost = data.get("cost") or {}
usd = cost.get("total_cost_usd") or 0
added = cost.get("total_lines_added") or 0
removed = cost.get("total_lines_removed") or 0
mins = (cost.get("total_duration_ms") or 0) // 60000
time_fmt = f"{mins // 60}h{mins % 60}m" if mins >= 60 else f"{mins}m"
segments.append(
    f"${usd:.2f}{DOT}{GRN}+{added}{RST}/{RED}-{removed}{RST}{DOT}{time_fmt}"
)

# --- subscription rate limits: time until reset + used % (Pro/Max only) ---
# 1.6h 22% · 2.7d 10% — countdown colored by how much of the window is used
rl = data.get("rate_limits") or {}
now = time.time()
rl_parts = []
for unit, key, div in (("h", "five_hour", 3600), ("d", "seven_day", 86400)):
    win = rl.get(key) or {}
    resets = win.get("resets_at")
    if resets is None:
        continue
    left = max(0, resets - now) / div
    used = win.get("used_percentage") or 0
    rl_parts.append(f"{rl_color(used)}{left:.1f}{unit}{RST} {DIM}{int(used)}%{RST}")
if rl_parts:
    segments.append(DOT.join(rl_parts))

print(SEP.join(segments))
