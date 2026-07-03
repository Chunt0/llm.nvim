# TODO

## Machine setup (run manually — needs sudo password)

Fix root-owned `~/.ssh` so git push works without the workaround:

```bash
sudo chown -R chunt:chunt ~/.ssh && chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_rsa
```

After running it, ask Claude to migrate `~/.ssh_known_hosts` into `~/.ssh/known_hosts`
and remove the `core.sshCommand` workaround from `~/.gitconfig`.
