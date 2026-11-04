# Octobar

GitHub in the Noctalia bar: the pull requests that matter to you, what happened on them since you last looked, and how far behind your local branches are. It uses your existing GitHub CLI session and never stores a token.

Fork of [raycursive/github-prs](https://github.com/noctalia-dev/community-plugins/tree/main/github-prs).

## Plugin

| Field | Value |
| --- | --- |
| ID | `sn4pe/octobar` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `fetch` |

## Requirements

- `gh` on `PATH`, authenticated with `gh auth login`.
- `git` on `PATH` for tracked branches.
- `xdg-open` on `PATH` to open pull requests in the browser.
- `notify-send` (libnotify) on `PATH`, only for `clickable_notifications`.

## Install

```sh
noctalia msg plugins source add sn4pe git https://github.com/Sn4pe/noctalia-plugins
noctalia msg plugins enable sn4pe/octobar
```

Then add `sn4pe/octobar:bar` from **Settings → Bar → Widgets**.

## What it shows

- **bar**: number of open pull requests matching your rules, plus a bell with the unseen activity and `+N` with the commits your tracked branches are behind (tooltip per branch). The bell turns red when someone requested changes or CI failed, and tertiary for review requests. A red `!` means the last refresh failed. The tooltip summarizes pull requests by state, the latest activity and the branches. Click toggles the panel.
- **panel**: review badges count every reviewer, so a pull request shows `1/2 approved` until all of them approve. A pull request waiting for your review shows **Your review** even if others approved it. On top, an **Activity** section with the time of each entry and a **Mark as seen** button, then **Branches behind** (folded) when a tracked branch is behind, then the pull requests grouped by repository with CI and review badges. Repository groups start folded unless one of their pull requests needs you (your review, or CI failing or changes requested on yours), and a folded group shows one icon per pull request in that state. Activity covers approvals, change requests, comments and CI failures on your own pull requests, new review requests (from a rule with `review-requested:`) and mentions anywhere.
- **Desktop notifications** for each new activity entry. With `clickable_notifications`, clicking one opens the review or comment, and review requests, change requests and CI failures go out as `critical` with category `octobar.alert`, so a Noctalia notification filter (`match = "octobar.alert"`) can keep them on screen or play a sound.

Activity comes from the same GraphQL search as the pull request list, so it only covers pull requests your rules match. Add `mentions:@me` to the rules to catch mentions in pull requests you do not own. The first run starts from now: nothing that happened before is reported.

Reviews on your pull requests merged since the last refresh come from one extra search (`is:merged author:@me`), so an approval right before the merge is not lost. Pull requests closed without merging are not covered. After a long time offline, the first refresh reports everything since the last one at once.

Each refresh costs two GraphQL points per rule plus two for the merged search (about 200 points an hour with four rules at the default interval, out of 5000), and one REST call per tracked branch. If GitHub answers with a rate-limit error, every call pauses for 15 minutes.

## Settings

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `rules` | `string_list` | `author:@me` | GitHub search fragments, prefixed with `is:pr is:open`. One `gh api graphql` request per rule, plus one for merged pull requests. |
| `excluded_repositories` | `string_list` | `[]` | `*` globs. With `/` they match `owner/name`, without it only the name. |
| `ignored_authors` | `string_list` | `[]` | Logins whose activity is not reported, for bots that post as users. Accounts GitHub marks as bots are always ignored. |
| `notify` | `bool` | `true` | Desktop notifications for new activity. |
| `clickable_notifications` | `bool` | `false` | Send notifications through `notify-send` so a click opens the review or comment. Needs `notify-send` on `PATH`. |
| `tracked_branches` | `string_map` | `{}` | Local repository path to branch, e.g. `~/Projects/app` = `main`. The origin remote must point to GitHub. |
| `refresh_interval` | `int` | `180` | Seconds, minimum 30. |

The `bar` widget also has `glyph` and `hide_when_zero`.

Example for a declarative config:

```toml
[plugin_settings."sn4pe/octobar"]
rules = ["author:@me", "review-requested:@me", "mentions:@me"]
ignored_authors = ["ci-bot"]

[plugin_settings."sn4pe/octobar".tracked_branches]
"~/Projects/app" = "main"
```

## IPC

```sh
noctalia msg plugin sn4pe/octobar:fetch all refresh
noctalia msg plugin sn4pe/octobar:fetch all dump
noctalia msg plugin sn4pe/octobar:fetch all ack <activity-url>
noctalia msg panel-toggle sn4pe/octobar:panel
```

## Privacy

Every request goes through `gh`, with the authentication `gh` already has. Activity state (last query time and seen events) is kept in the plugin data directory. After each successful refresh the pull request list is also written there as `prs.json` (`{updatedAt, prs}`, `updatedAt` in Unix seconds), so other tools can reuse it without calling GitHub.

## License

MIT. See [LICENSE](../LICENSE).
