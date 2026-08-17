# claude-review

Automated Claude Code review for GitLab merge requests. Drop the `claude-review/`
directory into any repo, add the CI job, and every MR gets reviewed by a panel of
specialist sub-agents that post inline discussions, reply to developer pushback,
and resolve their own threads once the code is fixed.

Project-agnostic: the agents learn your stack, layering, and review priorities by
reading your repo's own `CLAUDE.md` and `REVIEW.md`. Nothing here is tied to a
specific language or service.

## Install

1. Copy `claude-review/` into the target repo's root.
2. Build and push the job image:
   ```sh
   docker build -t <your-registry>/claude-review:latest claude-review/
   docker push <your-registry>/claude-review:latest
   ```
3. Include the job in `.gitlab-ci.yml`:
   ```yaml
   include:
     - local: '/claude-review/gitlab-ci-template.yml'

   stages:
     - code-review     # must exist
   ```
   Set `CLAUDE_REVIEW_IMAGE` to the image you just pushed. The template defaults to
   `$CI_REGISTRY_IMAGE/claude-review:latest` (your project's own GitLab registry).
4. Add the CI/CD variables below.
5. Write a `REVIEW.md` (see [Per-project configuration](#per-project-configuration)).

## CI/CD variables

**Required**

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `GITLAB_ACCESS_TOKEN` | Project Access Token, `api` scope — posts and resolves MR comments |

**Optional**

| Variable | Default | Purpose |
|---|---|---|
| `JIRA_API_TOKEN` | — | Jira API token. Absent → review skips with an explanatory MR comment |
| `JIRA_USERNAME` | — | Jira account email (required if `JIRA_API_TOKEN` is set) |
| `JIRA_HOST` | `xsolla.atlassian.net` | Jira hostname, no scheme |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Model for the orchestrator and all sub-agents |
| `DIFF_EXCLUDES` | `:!vendor/` | git pathspecs excluded from the review diff. Space-separated. `node_modules/`, `dist/`, generated dirs go here |

## How it works

```
run-review.sh
  ├─ pre-flight: required tokens present
  ├─ compute diff once  →  $WORK_DIR/diff.patch
  ├─ ticket gates ─────────── skip + comment if any fail:
  │    1. ticket key found in MR description or branch name
  │    2. Jira credentials configured
  │    3. ticket exists in Jira
  │    4. description ≥150 chars AND has Acceptance Criteria
  ├─ collect MR state  →  existing_threads / pending_replies / human_threads / human_notes
  ├─ claude -p  (orchestrator dispatches every sub-agent in parallel)
  │    └─ merge by root cause → dedup vs open threads → verify at file:line
  └─ post-review.sh
       ├─ resolve threads whose code is confirmed fixed
       ├─ reply to developers who pushed back
       ├─ post each finding as an inline discussion (falls back to a note)
       └─ replace the summary note
```

Everything runs in a `mktemp -d` work directory, wiped on exit — Jira content never
lands in shared `/tmp`.

Thread state lives in GitLab, not in a database. Findings carry a
`<!-- claude-review -->` marker and are matched by bot author ID, so re-running the
pipeline never duplicates comments and never touches other automations' threads.

## Per-project configuration

The agents read two files from your repo root. This is where all project knowledge
belongs — you should not need to edit the agent prompts.

**`CLAUDE.md`** — what the project is: stack, architecture, module layout, where
domain logic lives, security-critical invariants, generated paths that must not be
edited.

**`REVIEW.md`** — what reviewers should care about. A structure that works well:

```markdown
# Code Review Guidelines

## Always Check
- <invariants that must never break, e.g. PII never appears in logs>

## Security Focus
- <threat-model specifics for this service>

## Performance Focus
- <known hot paths, query patterns, cache expectations>

## Architecture Focus
- <layering rules, e.g. handlers must not bypass the service layer>

## Skip — do NOT review these
- `<generated/>` — generated code
- `<vendor/>` — dependencies
```

Sub-directories can carry their own `CLAUDE.md` / `REVIEW.md`; agents read those too
when the diff touches them. Useful for monorepos where each service has different
rules.

## Changing the agent roster

The roster is defined in exactly one place: `claude-review/review-agents.json`. Add,
remove, or rewrite entries freely — the schema accepts any set of agent keys and the
summary note renders whatever it receives. No other file needs editing.

Each entry takes `description`, `prompt`, `tools`, and `model`. Use `__MODEL__` as the
model value to inherit `CLAUDE_MODEL`, or pin a specific model id.

The default roster is `security`, `performance`, `correctness`, `architecture`, and
`ticket-alignment`.

## Files

| File | Role |
|---|---|
| `run-review.sh` | Orchestrator: gates, context collection, invokes Claude |
| `post-review.sh` | Posts inline discussions, replies, resolutions, summary |
| `review-agents.json` | Sub-agent roster — the per-project customization point |
| `review-prompt.md` | Orchestrator system prompt: merge, dedup, verify rules |
| `review-schema.json` | Structured-output contract |
| `Dockerfile` | Job image: node + git/jq/curl/bash + claude-code |
| `gitlab-ci-template.yml` | Includable CI job |

## Verifying changes

```sh
bash -n claude-review/run-review.sh claude-review/post-review.sh
jq empty claude-review/review-agents.json claude-review/review-schema.json
```

## Scope

GitLab merge requests only. `post-review.sh` speaks the GitLab discussions API
directly — there is no forge abstraction, and GitHub is not supported.
