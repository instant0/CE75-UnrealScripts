# UnrealEdit75 — agent rules

## THINK SMALL FIRST, NOT BIG

Default to the **smallest useful** answer, script, plan, or change. Expand only if needed or requested.

- CE / Lua diagnostics: short `print` probes (a few lines of output), not mega-scripts.
- Code changes: minimal safe edits; no speculative refactors.
- Prefer one check → result → next step, over one giant dump.

(Home rule: `~/.grok/rules/think-small-first.md`.)

## Do not restate user-run results

If the user ran your code and reports the output, **do not** explain what the code did or restate what the result means unless they ask. Assume competence. Next step or fix only.

(Home rule: `~/.grok/rules/dont-restate-user-results.md`.)

## I AM AN IDIOT AT WRITING AOB SCANS SO I NEED TO VERIFY THESE AFTER EVERY EDIT

Assume any AOB-related change is wrong until re-checked. After **every** edit that touches AOB scan code (patterns, loops, `AOBScan` / `AOBScanUnique` / `AOBScanModuleUnique`, protection flags, hit caps, locate helpers):

1. **Count the scans** — how many `AOBScan*` calls can run on one locate? Default budget: **1–2**. Never “try every register/modrm variant” as N full-process scans.
2. **Scope** — prefer `+X` (executable only) or module-unique; never full-process multi-pattern storms.
3. **Caps** — hard limit hits processed (e.g. ≤12); stop on first validated candidate.
4. **Cost check** — before finishing the edit, re-read the function and confirm it cannot fan out into dozens of scans or a pure-Lua walk of the whole module “just in case.”
5. **If unsure** — one narrow scan + manual `UEngine.*Addr` override path; do not “be thorough” with more AOBs.

