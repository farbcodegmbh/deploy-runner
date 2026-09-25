# deploy-runner

Builds a project's frontends on its own Laravel Forge server, outside Forge's 10-minute deploy limit, and
then starts the site's Forge deploy for exactly that commit. A self-hosted GitHub Actions runner does the
build under an unprivileged user; Forge keeps the deploy, its history and its notifications. It needs no
hosted runner minutes and no extra server.

[setup.sh](setup.sh) installs the server side. The build script, the workflow and the Forge deploy script
belong to each project.

## How it fits together

1. A push to the deploy branch starts the project's deploy workflow on `[self-hosted, <target>]`.
2. A pre-job hook checks the workflow and branch against an allow list and refuses everything else before
   the first step runs.
3. The project's build script writes `/srv/builds/<target>/<commit>/` and a `.complete` marker in it,
   running as `builder`, which can read neither the site's `.env` nor its releases.
4. The workflow calls the site's Forge deploy hook with `&sha=<commit>`.
5. Forge's deploy script checks out that commit, copies that commit's build into the release and deploys.

## Setting up a server

Download the script pinned to a commit, not a branch, so a later push cannot change what runs as root.
Read it, then run it as root from the Forge site's directory. Never pipe it into `sudo bash`: its prompts
would read the script itself.

```bash
curl -fsSLo ~/runner-setup.sh https://raw.githubusercontent.com/farbcodegmbh/deploy-runner/<commit>/setup.sh
```

```bash
cd /home/forge/example.com && sudo bash ~/runner-setup.sh
```

It reads the repository and branch from the site's checkout, suggests the target from the site's name
and the workflow from the target, and asks for each app's build `.env`. Nothing changes before you
confirm a summary. The answers are saved per target in `/etc/deploy-runner/NAME/setup.conf`, so a second
run asks nothing, and every step checks what is already there. Every answer can be passed instead, which skips its question:

| Option | Meaning |
|--------|---------|
| `--repo OWNER/REPO` | the GitHub repository the runner registers with |
| `--branch BRANCH` | the branch that deploys to this site |
| `--target NAME` | runner label, `/srv/builds/NAME` and `/etc/deploy-runner/NAME` |
| `--workflow FILE` | the deploy workflow in `.github/workflows`; with the branch, the only thing the runner accepts, for `push` and `workflow_dispatch` |
| `--env APP=FILE` | an app's build-time `.env`, copied to `/etc/deploy-runner/NAME/APP/.env`; repeatable |
| `--npmrc FILE` | copied next to every `--env`, for private packages |
| `--runner-dir DIR` | where the runner lives, default `/home/builder/runners/NAME` |
| `--yes` | skips the confirmation; required without a terminal |

**Build env files become readable by the build user.** Give it only a frontend's build values, never the
site's Laravel `.env` or anything else holding secrets.

It asks for two secrets without echoing them:

- **The site's deploy hook URL:** Forge → the site → Deployments → Deploy hook.
- **A runner registration token,** valid for an hour: repository Settings → Actions → Runners → New
  self-hosted runner, or

```bash
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token
```

## What the project provides

**A workflow** on the runner:

```yaml
name: Deploy testing

on:
  push:
    branches: [develop]
  workflow_dispatch:

# one run at a time; a newer push replaces the waiting one
concurrency:
  group: deploy-testing
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  deploy:
    runs-on: [self-hosted, NAME]
    env:
      BUILD_ROOT: /srv/builds/NAME
      BUILD_ENV_DIR: /etc/deploy-runner/NAME
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          clean: false                 # keeps node_modules between runs
          persist-credentials: false   # the checkout persists, the token must not
      - run: bash path/to/build-script.sh   # writes $BUILD_ROOT/<commit>/ and .complete
      # the hook URL carries a token, so it is never echoed
      - run: |
          sha=$(git rev-parse HEAD)
          curl -fsS --retry 3 -o /dev/null -X POST "$(cat "$BUILD_ENV_DIR/forge-deploy-hook")&sha=$sha&forge_deploy_commit=$sha"
```

**A Forge deploy script** that deploys the built commit and nothing else. Forge passes `&sha=` in as
`FORGE_VAR_SHA`:

```bash
$CREATE_RELEASE()

cd $FORGE_RELEASE_DIRECTORY

BUILDS=/srv/builds/NAME
SHA="${FORGE_VAR_SHA:-$(git rev-parse HEAD)}"
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "not a commit sha: $SHA"
    exit 1
fi
if [ ! -f "$BUILDS/$SHA/.complete" ]; then
    echo "no build for $SHA, run the deploy workflow for it"
    exit 1
fi
if [ "$(git rev-parse HEAD)" != "$SHA" ]; then
    git fetch --depth=1 origin "$SHA"
    git checkout --force --detach "$SHA"
fi

# copy (not link) the build into the release, so the build user cannot change a live release
# then the usual composer, migrate and cache steps

$ACTIVATE_RELEASE()
```

Then, in Forge, turn push to deploy off for the site: the push goes to the runner, which starts the
deploy once the build exists.

## Security

- **Same exposure as push to deploy.** A push to the deploy branch runs repository code on the server
  either way, through the build and through composer, npm and artisan in Forge's script. The hook keeps
  every other branch and workflow off the server.
- **The hook and its allow list are root-owned.** An allowed job runs as `builder`, which owns the
  runner's directory, so it could remove the hook for later jobs. Only a push to the deploy branch gets
  that far.
- **One server builds only for itself.** A runner never builds artifacts for another server.
- **Register the runner on the repository, never on the organisation,** and never for a public
  repository, where a fork's pull request could run code on it.
- **Test the hook after setup:** a workflow on another branch aimed at `[self-hosted, NAME]` must fail
  in "Set up runner" before its first step.
