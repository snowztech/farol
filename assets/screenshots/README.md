# Screenshots

A shot of each feature, for the docs and future posts. Every image is 2540x1520, taken from Farol Shots on the shelf demo, with a real Claude Code reviewing `src/queue.ts` in the main session.

Retake them all with `./scripts/shots.sh library` after `make shots`. It stages once, then reopens Farol Shots before each shot so nothing carries over. Copy a shot into `site/features/` to publish it.

| File | Shows |
|---|---|
| `sidebar.png` | Sessions grouped by project, working, waiting with the agent's question, and done, a folded project and tasks for later |
| `review-notes.png` | The review panel on the agent's changes, with a note under two README lines and Send 2 notes |
| `commit.png` | The commit sheet with a message typed, over the review panel |
| `git-graph.png` | The git graph's branches and history beside the agent |
| `files.png` | The files panel with `src/queue.ts` open in the editor beside the agent |
| `find-in-files.png` | Find in Files for `pending`, followed to line 7 with every match marked |
| `palette.png` | ⌘P with a session, the project's `test` command and test files |
| `new-task.png` | The New Task sheet, starting from origin's default branch, with Claude Code picked and Now beside Start |
| `settings.png` | Settings, on the Terminal page |
| `split.png` | Claude Code with a pane split beside it, checking the branch's history |
| `conflicts.png` | Merging main into a branch stopped on a conflict, in the three-column resolver |

Not here yet: servers in the sidebar, the menu bar and notch panels, a light theme, the task editor and the iPhone app.
