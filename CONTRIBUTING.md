# Contributing

Thanks for helping. Small, focused pull requests are the easiest to review and merge. For a new feature, open an issue first: [ROADMAP.md](ROADMAP.md) lists what's planned and what's not.

## Run it

You need macOS 14 or later and Xcode 26.

```sh
git clone https://github.com/<you>/farol && cd farol
make run
```

The first build downloads a prebuilt libghostty. `make run` builds **Farol Dev**, a separate app with its own settings and sessions, so it runs next to an installed Farol without touching it.

## Before you open a PR

```sh
make test
make lint
```

- Branch from `main`. One change per PR.
- Commits are one line in the Conventional Commits style: `fix(sidebar): keep the selected session in view`.
- If users would notice the change, add a line under **Unreleased** in `CHANGELOG.md`.
- For UI changes, add a screenshot.
- Screenshots for the site come from Farol Shots, so they look the same on any Mac: `make shots SCENE=review` opens a staged demo, set up anything else by hand, then `make shot NAME=review` saves `site/features/review.png`. Your terminal app needs Screen Recording.
- If your change runs git or touches the main thread, press ⌥⌘I in Farol for the Farol Inspector. It shows the programs Farol starts, like git, freezes since launch and any process that blocks the window, memory and CPU. Click any reading to see what it means. Copy Report gives a before and after to paste in the PR.
- When the code has grown, `make audit` lists what smells in seconds: functions too long or too tangled, and force unwraps. `make unused` lists code and imports nothing uses, and takes a few minutes since it builds from scratch. Both need SwiftLint (`brew install swiftlint`), change nothing, and write the full list to `build/audit.md` or `build/unused.md` to hand to an agent. Neither is required for a PR.
- To see why something is slow, `make profile` records an optimized Farol Dev with Instruments for 30 seconds while you use it, then says whether anything stands out: freezes and busy CPU. The details, like each freeze and the heaviest functions, go to `build/profile.md` to hand to an agent. The Inspector covers git and the other commands. Quit Farol Dev first.

## Writing

Farol's docs, comments and PRs are short and plain. `make lint` checks part of it.

- Say what changed and why, in a few sentences. Skip summaries of the diff, headings for one line of text, and lists of every file touched.
- Comments explain why, not what the code does.
- Plain words. No em dashes.

AI tools are welcome. You're responsible for what they write: read it, trim it and test it before you open the PR.

## Where to start

Issues labeled [good first issue](https://github.com/snowztech/farol/labels/good%20first%20issue) are small and well scoped.
