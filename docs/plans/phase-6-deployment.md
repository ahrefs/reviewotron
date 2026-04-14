# Phase 6: Deployment

## Goal
Move the app from `experimental/` to `backend/`, register it in the monorepo's CI/deployment system, and configure end-to-end deployment with GitHub webhook integration. This phase is executed when the app is validated and ready for production use.

## Prerequisites
- Phases 1-5 complete and all tests passing
- App has been manually tested against real PRs (via `check` command or temporary webhook)
- Read `.cursor/rules/backend-developer.mdc` for code style
- Use serena to navigate `backend/admin/cluster.ml` and `backend/gen_ci/ci_apps.ml`

## Tasks

### 6.1 Move to `backend/reviewotron/`

Move the entire app:
```bash
mv experimental/reviewotron backend/reviewotron
```

Update `Makefile` to use the standard backend pattern:
```makefile
DEFAULT_TARGET = @all
include ../shared-makefiles/dune.mk
```

Update `dune-project` if needed — verify the build still works from the new location.

Update any internal path references (mock payload paths in tests, etc.).

### 6.2 Create opam deps package

Create `backend/opam/packages/ahrefs-reviewotron-deps/ahrefs-reviewotron-deps.YYYYMMDD/opam`:

```
opam-version: "2.0"
depends: [
  "containers"
  "devkit"
  "lwt"
  "cmdliner"
  "yojson"
  "atdgen"
  "atdgen-runtime"
  "digestif"
  "curl"
  "re2"
  "ptime"
  "alcotest" {with-test}
]
```

Note: Check what's actually available in the monorepo's opam setup — some dependencies may be provided transitively through `ahrefskit` or similar meta-packages.

### 6.3 Register binary in `cluster.ml` — Bin module

**File**: `backend/admin/cluster.ml`

Add in the `Bin` module section (find where similar small apps like `slack_of_ics` are defined):

```ocaml
let reviewotron = {
  exe = native "reviewotron.exe";
  build = "make -C reviewotron build";
  source = "backend/reviewotron";
  artifact = build "reviewotron/src/reviewotron.exe";
}
```

### 6.4 Create tool template in `cluster.ml` — Prod module

Add in the `Prod` module section:

```ocaml
let reviewotron = new_tool "reviewotron" Bin.reviewotron
  ~alert:running
  ~managed:(Systemd Systemd_unit_puppet)
  ~json_logs:true
  ~suggested_pid_name:`Tool_name
  ~info:{
    ppl = [ (* your team contact *) ];
    href = [ "https://github.com/ahrefs-core/monorepo/blob/develop/backend/reviewotron/README.md" ];
    comments = None;
    safety = should_keep_running;
    area = Some Infra;
  }
  (admin_systemd ~extra:[
    "--secrets=/etc/reviewotron/secrets.json";
    "--config=/etc/reviewotron/config.json";
    "--state=/var/lib/reviewotron/state.json";
    "--port=8095";
  ])
```

Note: Choose a port that doesn't conflict with existing services. Check existing tool registrations for port assignments.

### 6.5 Register tool instance in `cluster.ml` — Staging section

```ocaml
let reviewotron = reg_user1
  ~root:"reviewotron_be/develop/current"
  ~ci_branch:(Branch "develop")
  reviewotron Nodes.devsg ()
```

### 6.6 Register app in `ci_apps.ml`

**File**: `backend/gen_ci/ci_apps.ml`

Add the app definition:
```ocaml
let reviewotron = make_app "reviewotron" Cluster.reviewotron
  ~trigger:(`Deps [])
  ~has_secrets:true
  ~should_deploy:deploy_when_changed_on_develop
```

Add to the `staging_as_prod_apps` list:
```ocaml
let staging_as_prod_apps =
  List.map
    (fun x -> x Cluster.Prod.realm)
    [
      (* ... existing apps ... *)
      reviewotron;
    ]
```

### 6.7 Create production config file

`/etc/reviewotron/config.json` (to be deployed on the target node):
```json
{
  "max_diff_lines": 2000,
  "max_files": 50,
  "max_tokens_per_review": 100000,
  "model": "claude-sonnet-4-5-20250929",
  "ignored_paths": [
    "*.lock",
    "vendor/*",
    "_build/*",
    "*.generated.*",
    "*.min.js",
    "*.min.css"
  ],
  "ignored_authors": [
    "dependabot[bot]",
    "renovate[bot]"
  ],
  "auto_review_pr_open": true,
  "auto_review_pr_sync": true,
  "review_pushes_to_develop": true,
  "slack_webhook_url": "https://hooks.slack.com/services/T.../B.../xxx",
  "slack_channel": "#code-reviews"
}
```

### 6.8 Deploy secrets

`/etc/reviewotron/secrets.json` (sensitive — deploy via puppet/ansible):
```json
{
  "repos": [
    {
      "url": "https://github.com/ahrefs-core/monorepo",
      "gh_token": "ghp_...",
      "gh_hook_secret": "..."
    }
  ],
  "anthropic_api_key": "sk-ant-...",
  "anthropic_version": "2023-06-01"
}
```

### 6.9 Configure GitHub webhook

In the repository settings (Settings → Webhooks → Add webhook):

| Field | Value |
|-------|-------|
| Payload URL | `https://reviewotron.devsg.ahrefs.com/github` (or appropriate internal URL) |
| Content type | `application/json` |
| Secret | Same value as `gh_hook_secret` in secrets.json |
| Events | `Pull requests`, `Pushes` |
| Active | Yes |

### 6.10 End-to-end verification

1. **Deploy**: Push to develop, verify CI picks up reviewotron and deploys it
2. **Health check**: `curl https://reviewotron.devsg.ahrefs.com/ping` returns 200
3. **PR review test**: Open a test PR with a small code change, verify:
   - Review is posted within 30-60 seconds
   - Inline comments appear on the correct lines
   - Summary is coherent and useful
4. **Push review test**: Push a change to develop, verify:
   - Commit comments appear on GitHub
   - Slack message is posted to the configured channel
5. **Duplicate test**: Push the same PR update (force push same SHA), verify no duplicate review
6. **Error test**: Check logs for any errors or warnings during the above tests

### 6.11 Create README.md

Create `backend/reviewotron/README.md` documenting:
- What the app does
- How to configure it (config.json, secrets.json)
- How to run locally for testing
- How to add a new repository
- Architecture overview (brief)
- Troubleshooting common issues

## Verification

1. CI pipeline successfully builds and deploys reviewotron on push to develop
2. Service is running and healthy on target node
3. PR review works end-to-end on a real PR
4. Push review works end-to-end on a real push to develop
5. Slack notifications are received
6. No duplicate reviews on repeated events
7. Service restarts cleanly after a crash (systemd manages it)

## QA Checklist
- [ ] Binary compiles and runs on target node
- [ ] Systemd unit is properly configured and monitored
- [ ] Secrets are not committed to the repo
- [ ] Port doesn't conflict with other services
- [ ] Logs are JSON-formatted and visible in monitoring
- [ ] GitHub webhook signature validation works in production
- [ ] Rate limiting: verify we don't hit Anthropic API rate limits
- [ ] State file persists across restarts
- [ ] README is accurate and helpful
