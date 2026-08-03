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

