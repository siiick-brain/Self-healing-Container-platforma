# Project rules

- Davis Asoka (@siiick-brain) is the sole repository author. Leave changes staged for Davis to commit and push.
- Omit co-author trailers, generation credits and tool attribution from repository content and pull requests.
- Use Copilot for editor help and PR review. Keep issues unassigned to its coding agent.
- Disable Claude Code co-author attribution and set commit and PR attribution strings to empty.
- Run project commands in WSL2 with Docker. Write shell scripts in Bash.
- Keep cost at zero. Use public GitHub Actions and GHCR and local MinIO. Validate AKS statically and never apply it.
- Read CONTRACTS.md and files within your assigned scope. Use the graphify graph for other context.
- Check current tool and chart syntax with context7. Use the least expensive model suited to the task.
- Make the smallest patch that satisfies acceptance. One issue per PR. Stop when the checklist passes.
- Reports include the checklist and the last ten lines of each proof command.
- Keep comments rare and one line long. Explain why. Skip banners, step numbering, emoji and em dashes.
- Use plain language. Avoid the Oxford comma and the terms enforced by scripts/lint-prose.sh.
- Use imperative Conventional Commits under 72 characters. Run humanizer on README, docs and commit messages before merge.
- Link numeric claims to recorded evidence under results/. Label estimates and include the formula.
- Mark fixed numeric targets with the HTML target marker. Keep CONTRACTS.md owner-edited.
