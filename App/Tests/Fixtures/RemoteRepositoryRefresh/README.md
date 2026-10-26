# Remote repository refresh replies

Output of `RemoteRepositoryRefresh.scriptText`, recorded on 2026-10-23:

- `macos-*.txt`: on a Mac host (macOS 26.5, git 2.50.1 Apple Git-155, `/bin/bash` 3.2) over
  `ssh … bash -s`;
- `linux-worktrees.txt`: in a Debian 13 container (git 2.47.3, bash 5.2, GNU coreutils 9.7)
  with `bash -s`. `/tmp` is not a link there, so the root is not resolved.

The fixture repository on the host:

- `/tmp/prowl-b3-fx/app`, opened through the link `/tmp/prowl-b3-fx/link/app`
  (on the Mac, `/tmp` is also a link to `/private/tmp`). Its main worktree has 2 added and 1 removed
  tracked lines in `a.txt`, a changed binary file, 2 untracked files and one ignored
  folder.
- the linked worktree `app feature` (a space in the path) on `feature/login`, with
  1 added line;
- the detached worktree `app-detached`;
- the worktree `app-gone`, whose folder was deleted;
- the bare repository `/tmp/prowl-b3-fx/bare.git`;
- the plain folder `/tmp/prowl-b3-fx/plain`, and the missing path `/tmp/prowl-b3-fx/none`.

After the change that tells a hidden path from a missing one (review round 1 of #972), the
script ran again on the same Mac fixtures and gave the same records; only the commit IDs
and creation times of the recreated fixture differ, so the files were kept.
