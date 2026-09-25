#!/usr/bin/env bash
#
# Sets up a deploy runner on a Forge server: a GitHub Actions runner under the unprivileged `builder` user
# that builds a project's frontends beside the site and then starts the site's Forge deploy.
# How it fits together and what stays manual: README.md of https://github.com/farbcodegmbh/deploy-runner
#
# Safe to re-run: every step checks what is already there. It asks for two secrets and neither reaches a
# command line, the process list or the log: the runner registration token and the site's Forge deploy
# hook URL.
#
# Run as root on the server:
#   sudo bash setup.sh --repo OWNER/REPO --target NAME --workflow FILE --branch BRANCH \
#       [--env APP=FILE]... [--npmrc FILE] [--runner-dir DIR]
#
#   --target      names the runner label, /srv/builds/NAME and /etc/deploy-runner/NAME
#   --workflow    the deploy workflow's file name in .github/workflows; with --branch it is the only
#                 thing the runner accepts
#   --env         an app's build-time .env, copied to /etc/deploy-runner/NAME/APP/.env
#   --npmrc       copied next to every --env
#   --runner-dir  defaults to /home/builder/runners/NAME

set -euo pipefail

user=builder
etc=/etc/deploy-runner

repo="" target="" workflow="" branch="" npmrc="" runner_dir=""
envs=()

usage() {
    echo "usage: sudo bash $0 --repo OWNER/REPO --target NAME --workflow FILE --branch BRANCH [--env APP=FILE]... [--npmrc FILE] [--runner-dir DIR]" >&2
    exit 2
}

fail() {
    echo "$*" >&2
    exit 1
}

step() {
    echo "== $*"
}

while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || usage
    case "$1" in
        --repo)       repo=$2 ;;
        --target)     target=$2 ;;
        --workflow)   workflow=$2 ;;
        --branch)     branch=$2 ;;
        --env)        envs+=("$2") ;;
        --npmrc)      npmrc=$2 ;;
        --runner-dir) runner_dir=$2 ;;
        *)            usage ;;
    esac
    shift 2
done

[ -n "$repo" ] && [ -n "$target" ] && [ -n "$workflow" ] && [ -n "$branch" ] || usage
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repo expects OWNER/REPO"
[[ "$target" =~ ^[a-z0-9-]+$ ]] || fail "--target takes lowercase letters, digits and dashes"
[[ "$workflow" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || fail "--workflow expects a file name such as deploy-testing.yml"
[ -z "$npmrc" ] || [ -f "$npmrc" ] || fail "--npmrc $npmrc does not exist"
for pair in "${envs[@]}"; do
    [[ "${pair%%=*}" =~ ^[a-z0-9-]+$ ]] && [ -f "${pair#*=}" ] || fail "--env $pair: expected APP=existing file"
done
[ "$(id -u)" = 0 ] || fail "run as root: sudo bash $0 ..."
for tool in curl tar python3 sha256sum systemctl; do
    command -v "$tool" >/dev/null || fail "missing on this server: $tool"
done

builds=/srv/builds/$target
env_dir=$etc/$target
runner_dir=${runner_dir:-/home/$user/runners/$target}
runner_name="$(hostname)-$target"

step "build user"
if id "$user" >/dev/null 2>&1; then
    echo "$user exists"
else
    adduser --system --group --shell /bin/bash --home "/home/$user" "$user"
fi
if ! sudo -u "$user" -i sh -c 'node -v && yarn -v' >/dev/null 2>&1; then
    echo "warning: node or yarn is not on $user's PATH, and the builds need both" >&2
fi

step "directories"
install -d -o "$user" -g "$user" -m 755 "$builds"
install -d -o root -g "$user" -m 750 "$etc" "$env_dir"

step "guard"
# installed root-owned, so no job can change the check that decides which jobs run
cat > "$etc/pre-job.sh" <<'HOOK'
#!/usr/bin/env bash
# Pre-job hook of a deploy runner (ACTIONS_RUNNER_HOOK_JOB_STARTED), written by deploy-runner's setup.sh.
# A non-zero exit fails the job before its first step, so only the workflows in the allow file run on this
# server. GitHub sets the GITHUB_* values and a workflow cannot overwrite them.
set -euo pipefail
allow=/etc/deploy-runner/allow
job="${GITHUB_EVENT_NAME:-} ${GITHUB_WORKFLOW_REF:-}"
if grep -qxF -- "$job" "$allow"; then
    exit 0
fi
echo "This runner only runs the workflows in $allow. Refused: $job" >&2
exit 1
HOOK
chown root:root "$etc/pre-job.sh"
chmod 755 "$etc/pre-job.sh"
touch "$etc/allow"
chmod 644 "$etc/allow"
for event in push workflow_dispatch; do
    line="$event $repo/.github/workflows/$workflow@refs/heads/$branch"
    if ! grep -qxF -- "$line" "$etc/allow"; then
        echo "$line" >> "$etc/allow"
    fi
done
cat "$etc/allow"

step "build env"
for pair in "${envs[@]}"; do
    app=${pair%%=*}
    install -d -o root -g "$user" -m 750 "$env_dir/$app"
    install -o root -g "$user" -m 640 "${pair#*=}" "$env_dir/$app/.env"
    if [ -n "$npmrc" ]; then
        install -o root -g "$user" -m 640 "$npmrc" "$env_dir/$app/.npmrc"
    fi
    echo "$app"
done

step "deploy hook"
hook_file=$env_dir/forge-deploy-hook
if [ -s "$hook_file" ]; then
    echo "already stored in $hook_file"
else
    read -rs -p "Forge deploy hook URL of the site (Deployments > Deploy hook): " hook_url
    echo
    [[ "$hook_url" =~ ^https://forge\.laravel\.com/servers/[0-9]+/sites/[0-9]+/deploy/http\?token=[A-Za-z0-9]+$ ]] \
        || fail "that is not a Forge deploy hook URL"
    install -o root -g "$user" -m 640 /dev/null "$hook_file"
    printf '%s' "$hook_url" > "$hook_file"
    unset hook_url
fi

step "runner"
if [ -f "$runner_dir/.runner" ]; then
    echo "already registered in $runner_dir"
else
    case "$(uname -m)" in
        x86_64)  arch=x64 ;;
        aarch64) arch=arm64 ;;
        *)       fail "no runner build for $(uname -m)" ;;
    esac
    # the release API publishes each asset's sha256, so the download is checked against GitHub's own digest
    read -r tarball_url digest < <(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | python3 -c '
import json, re, sys
for asset in json.load(sys.stdin)["assets"]:
    if re.fullmatch(r"actions-runner-linux-" + sys.argv[1] + r"-[0-9.]+\.tar\.gz", asset["name"]):
        print(asset["browser_download_url"], asset["digest"].removeprefix("sha256:"))
' "$arch") || fail "no runner release found for linux-$arch"
    tarball=$(mktemp)
    curl -fsSL -o "$tarball" "$tarball_url"
    echo "$digest  $tarball" | sha256sum -c --quiet || fail "runner download does not match its published sha256"
    install -d -o "$user" -g "$user" -m 750 "$runner_dir"
    tar -xzf "$tarball" -C "$runner_dir"
    rm -f "$tarball"
    chown -R "$user:$user" "$runner_dir"
    echo "installed $(basename "$tarball_url")"

    read -rs -p "Runner registration token (repo Settings > Actions > Runners > New self-hosted runner): " ACTIONS_RUNNER_INPUT_TOKEN
    echo
    export ACTIONS_RUNNER_INPUT_TOKEN
    (cd "$runner_dir" && sudo -u "$user" --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN \
        ./config.sh --unattended --url "https://github.com/$repo" --name "$runner_name" --labels "$target" --work _work --replace)
    unset ACTIONS_RUNNER_INPUT_TOKEN
fi

hook_line="ACTIONS_RUNNER_HOOK_JOB_STARTED=$etc/pre-job.sh"
hook_added=0
if ! grep -qxF -- "$hook_line" "$runner_dir/.env" 2>/dev/null; then
    echo "$hook_line" >> "$runner_dir/.env"
    chown "$user:$user" "$runner_dir/.env"
    hook_added=1
fi

step "service"
cd "$runner_dir"
if [ ! -f .service ]; then
    ./svc.sh install "$user"
    ./svc.sh start
elif [ "$hook_added" = 1 ]; then
    # the runner reads .env only at start
    ./svc.sh stop
    ./svc.sh start
fi
echo "$(cat .service): $(systemctl is-active "$(cat .service)")"

cat <<DONE

Server side done. Still by hand (README.md of farbcodegmbh/deploy-runner):
  - Forge: paste the site's deploy script, turn push to deploy off
  - repo: .github/workflows/$workflow on [self-hosted, $target], BUILD_ROOT=$builds, BUILD_ENV_DIR=$env_dir
  - Slack: /github subscribe $repo workflows:{name:"<workflow name>" branch:"$branch"}
  - guard test: a workflow on another branch aimed at [self-hosted, $target] must fail in "Set up runner"
DONE
