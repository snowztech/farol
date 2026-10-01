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

## Writing

Farol's docs, comments and PRs are short and plain. `make lint` checks part of it.

- Say what changed and why, in a few sentences. Skip summaries of the diff, headings for one line of text, and lists of every file touched.
- Comments explain why, not what the code does.
- Plain words. No em dashes.

AI tools are welcome. You're responsible for what they write: read it, trim it and test it before you open the PR.

## Where to start

Issues labeled [good first issue](https://github.com/snowztech/farol/labels/good%20first%20issue) are small and well scoped.
