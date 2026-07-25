#!/usr/bin/env python3
"""Multi-skill trigger eval for the mentor plugin.

The stock skill-creator harness exposes ONE skill and asks "did it fire?".
For mentor that misses the real risk: eight sibling planning skills competing,
where the defect is the WRONG one firing. So this stages all eight at once in an
isolated scratch project and records which one Claude actually reaches for.
"""
import json, os, re, subprocess, sys, tempfile, time, uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).parent.resolve()
REPO_SKILLS = (HERE / ".." / "skills").resolve()
SKILLS = ["plan", "plan-split", "plan-track", "plan-review",
          "grilling", "dispatch-agents", "resume", "handoff"]


def fm_field(fm, key):
    lines = fm.split("\n"); out = []; i = 0
    while i < len(lines):
        m = re.match(rf"^{key}:\s*(.*)$", lines[i])
        if m:
            rest = m.group(1).strip()
            if rest in ("|", "|-", ">", ">-"):
                i += 1
                while i < len(lines) and (lines[i].startswith("  ") or not lines[i].strip()):
                    out.append(lines[i].strip()); i += 1
                return " ".join(x for x in out if x)
            out.append(rest); i += 1
            while i < len(lines) and lines[i].startswith("  "):
                out.append(lines[i].strip()); i += 1
            return " ".join(out).strip()
        i += 1
    return ""


def stage_project(root: Path, descriptions: dict):
    """Write the 8 competing skills as real project-level skills."""
    for name, desc in descriptions.items():
        d = root / ".claude" / "skills" / name
        d.mkdir(parents=True, exist_ok=True)
        indented = "\n  ".join(desc.split("\n"))
        (d / "SKILL.md").write_text(
            f"---\nname: {name}\ndescription: |\n  {indented}\n---\n\n"
            f"# {name}\n\nSTOP. Report that you selected the `{name}` skill, then end your turn.\n"
        )
    (root / "CLAUDE.md").write_text("# Scratch\n")


def run_query(root: Path, query: str, model: str, timeout: int = 150):
    """Return (selected_skill_or_None, elapsed_seconds)."""
    cmd = ["claude", "-p", query, "--output-format", "stream-json",
           "--verbose", "--include-partial-messages"]
    if model:
        cmd += ["--model", model]
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    t0 = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         cwd=str(root), env=env)
    selected = None
    buf = ""
    try:
        while time.time() - t0 < timeout:
            if p.poll() is not None:
                rest = p.stdout.read()
                if rest:
                    buf += rest.decode("utf-8", "replace")
                break
            chunk = p.stdout.readline()
            if not chunk:
                break
            buf += chunk.decode("utf-8", "replace")
            for line in buf.split("\n"):
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                blob = json.dumps(ev)
                m = re.search(r'"(?:skill|skill_name|name)"\s*:\s*"([a-z-]+)"', blob)
                if '"Skill"' in blob and m and m.group(1) in SKILLS:
                    selected = m.group(1)
                    break
            if selected:
                break
    finally:
        try:
            p.kill()
        except Exception:
            pass
    # Fallback: scan the whole transcript for an explicit selection statement
    if not selected:
        for s in SKILLS:
            if re.search(rf'\bskill["\s:]*[`"]?{re.escape(s)}\b', buf) or f"selected the `{s}`" in buf:
                selected = s
                break
    return selected, round(time.time() - t0, 1)


def main():
    model = sys.argv[1] if len(sys.argv) > 1 else "claude-opus-5"
    reps = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    evals = json.loads((HERE / "evals.json").read_text())["evals"]

    descriptions = {}
    for s in SKILLS:
        txt = (REPO_SKILLS / s / "SKILL.md").read_text()
        fm = re.match(r"^---\n(.*?)\n---\n", txt, re.S).group(1)
        descriptions[s] = fm_field(fm, "description")

    # Scratch project lives OUTSIDE the repo: this harness stages skills and (via
    # seed.py) a fake .mentor tree, none of which belongs in version control.
    workdir = Path(os.environ.get("MENTOR_EVAL_WORKDIR",
                                  Path(tempfile.gettempdir()) / "mentor-trigger-eval"))
    root = workdir / "project"
    root.mkdir(parents=True, exist_ok=True)
    stage_project(root, descriptions)
    print(f"staged {len(descriptions)} skills in {root}", flush=True)
    print(f"results -> {workdir}/results.json", flush=True)

    jobs = [(e, r) for e in evals for r in range(reps)]

    def work(job):
        e, r = job
        sel, secs = run_query(root, e["query"], model)
        ok = (sel or "none") == e["expected"]
        print(f"  [{'PASS' if ok else 'FAIL'}] #{e['id']} rep{r} "
              f"expected={e['expected']:<16} got={sel or 'none':<16} ({secs}s)", flush=True)
        return {"id": e["id"], "rep": r, "expected": e["expected"],
                "got": sel or "none", "pass": ok, "secs": secs,
                "tests": e["tests"], "query": e["query"]}

    with ThreadPoolExecutor(max_workers=6) as ex:
        results = list(ex.map(work, jobs))

    results.sort(key=lambda x: (x["id"], x["rep"]))
    (workdir / "results.json").write_text(json.dumps(results, indent=2))
    passed = sum(1 for r in results if r["pass"])
    print(f"\n=== {passed}/{len(results)} correct ({100*passed//len(results)}%) ===")
    for r in results:
        if not r["pass"]:
            print(f"  #{r['id']} expected {r['expected']:<16} got {r['got']:<16} | {r['tests']}")


if __name__ == "__main__":
    main()
