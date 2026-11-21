# Contributing

Davis owns all commits. Leave changes staged for owner review. After publishing the repository, enable squash merging only and protect the default branch with a pull request requirement and all checks from the Bootstrap workflow. Set the Actions repository variable `OWNER_EMAIL` to Davis's exact commit email. For web squash merges, the authorship check allows Davis's GitHub noreply address and the GitHub web-flow committer when paired with that owner's noreply address. Keep the repository public and run the project from WSL2.

Before project implementation, run the environment check in WSL2 with Docker running. Review results/env/wsl.txt for the tool list, memory and netem output.

```bash
bash scripts/check-environment.sh
```
