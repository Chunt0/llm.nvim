# TODO

## Next up (SPEC.md roadmap)

- **M2 leftovers**: session model for chat modes (removes the last global
  stream state, P13), mini.test headless-nvim integration harness, mock SSE
  server for e2e agent tests
- **M5 — chat polish**: persistent chat panel with folds/`@file`, session
  resume, follow-up turns in the agent panel, multi-edit review queue
  (`]e`/`[e`), OpenAI tool support, drop the old-namespace shims

## Machine setup (run manually — needs sudo password)

Fix root-owned `~/.ssh` so git push works without the workaround:

```bash
sudo chown -R chunt:chunt ~/.ssh && chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_rsa
```

After running it, ask Claude to migrate `~/.ssh_known_hosts` into `~/.ssh/known_hosts`
and remove the `core.sshCommand` workaround from `~/.gitconfig`.
