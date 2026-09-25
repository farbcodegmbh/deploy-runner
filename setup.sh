#!/usr/bin/env bash
#
# Sets up a deploy runner on a Forge server: a GitHub Actions runner under the unprivileged `builder` user
# that builds a project's frontends beside the site and then starts the site's Forge deploy.
# How it fits together and what stays manual: README.md of https://github.com/farbcodegmbh/deploy-runner
#
# Safe to re-run: every step checks what is already there, and the answers are saved per target, so a
# second run asks nothing. It asks for two secrets and neither reaches a command line, the process list or
# the log: the runner registration token and the site's Forge deploy hook URL.
#
# Run as root from the Forge site's directory, where it reads repository and branch from the site's
# checkout and asks for the rest:
#   cd /home/forge/example.com && sudo bash /path/to/setup.sh
# Every answer can also be passed, which skips its question:
#   --repo OWNER/REPO   the repository the runner registers with
#   --branch BRANCH     the branch that deploys to this site
#   --target NAME       runner label, /srv/builds/NAME and /etc/deploy-runner/NAME
#   --workflow FILE     the deploy workflow's file in .github/workflows; with the branch, the only thing
#                       the runner accepts
#   --env APP=FILE      an app's build-time .env, copied to /etc/deploy-runner/NAME/APP/.env; repeatable
#   --npmrc FILE        copied next to every --env, for private packages
#   --runner-dir DIR    defaults to /home/builder/runners/NAME
#   --yes               skips the confirmation, required without a terminal

set -euo pipefail

user=builder
etc=/etc/deploy-runner

repo="" target="" workflow="" branch="" npmrc="" runner_dir="" assume_yes=0
envs=()

usage() {
    sed -n '/^# Run as root/,/^$/s/^# \{0,1\}//p' "$0" >&2
    exit 2
}

fail() {
    echo "$*" >&2
    exit 1
}

step() {
    echo "== $*"
}

# ask VAR QUESTION [DEFAULT]: keeps a value that is already set, otherwise asks on the terminal
ask() {
    local var=$1 question=$2 default=${3:-} answer
    [ -z "${!var}" ] || return 0
    if [ ! -t 0 ]; then
        [ -n "$default" ] || fail "no --$var given and no terminal to ask on"
        printf -v "$var" '%s' "$default"
        return 0
    fi
    read -r -e -p "$question${default:+ [$default]}: " answer
    printf -v "$var" '%s' "${answer:-$default}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes)     assume_yes=1; shift; continue ;;
        -h|--help) usage ;;
    esac
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

[ "$(id -u)" = 0 ] || fail "run as root: sudo bash $0"
for tool in curl tar python3 sha256sum systemctl; do
    command -v "$tool" >/dev/null || fail "missing on this server: $tool"
done

# a Forge site directory: its checkout names the repository and the branch
site="" site_repo="" site_branch=""
if [ -L current ] || [ -d releases ] || [ -d .git ]; then
    site=$PWD
    for git_dir in "$site/current/.git" "$site/.git"; do
        [ -f "$git_dir/config" ] || continue
        # -C / keeps git from looking at the surrounding checkout, which root does not own
        if url=$(git -C / config -f "$git_dir/config" remote.origin.url); then
            site_repo=$(sed -E 's#^(git@github\.com:|https://([^@/]+@)?github\.com/)##; s#\.git$##' <<< "$url")
            [[ "$site_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || site_repo=""
        fi
        site_branch=$(sed -n 's#^ref: refs/heads/##p' "$git_dir/HEAD")
        break
    done
fi

targets=()
for dir in "$etc"/*/; do
    [ -d "$dir" ] && targets+=("$(basename "$dir")")
done
if [ ${#targets[@]} -gt 0 ]; then
    echo "targets on this server: ${targets[*]}"
fi
target_default=""
if [ ${#targets[@]} -eq 1 ]; then
    target_default=${targets[0]}
elif [ -n "$site" ]; then
    target_default=$(basename "$site" | tr 'A-Z.' 'a-z-' | tr -cd 'a-z0-9-')
fi
ask target "Target name (runner label and folder name)" "$target_default"
[[ "$target" =~ ^[a-z0-9-]+$ ]] || fail "the target takes lowercase letters, digits and dashes"

# answers saved by an earlier run for this target
saved_repo="" saved_branch="" saved_workflow="" saved_runner_dir=""
if [ -f "$etc/$target/setup.conf" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            repo)       saved_repo=$value ;;
            branch)     saved_branch=$value ;;
            workflow)   saved_workflow=$value ;;
            runner_dir) saved_runner_dir=$value ;;
        esac
    done < "$etc/$target/setup.conf"
fi

ask repo "GitHub repository (OWNER/REPO)" "${saved_repo:-$site_repo}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "the repository has to be OWNER/REPO"
ask branch "Branch that deploys here" "${saved_branch:-${site_branch:-develop}}"
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "not a branch name: $branch"
ask workflow "Deploy workflow file in .github/workflows" "${saved_workflow:-deploy-$target.yml}"
[[ "$workflow" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || fail "the workflow is a file name such as deploy-testing.yml"
runner_dir=${runner_dir:-${saved_runner_dir:-/home/$user/runners/$target}}

builds=/srv/builds/$target
env_dir=$etc/$target
runner_name="$(hostname)-$target"

if [ ${#envs[@]} -eq 0 ] && [ -t 0 ]; then
    add_env=y apps=""
    if [ -d "$env_dir" ]; then
        apps=$(find "$env_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f ')
    fi
    if [ -n "$apps" ]; then
        echo "build env already stored for: $apps"
        read -r -p "Add or replace an app's build env? [y/N] " add_env
    fi
    if [[ "$add_env" =~ ^[yY] ]]; then
        echo "Build env, one frontend app at a time. The build user can read these files, so never give it"
        echo "the site's Laravel .env or anything else holding secrets."
        if [ -n "$site" ]; then
            echo "env files in this site: $(find "$site" "$site/shared" -maxdepth 1 -type f \( -name '.env*' -o -name '.npmrc' \) 2>/dev/null | tr '\n' ' ')"
        fi
        while read -r -e -p "App directory in the repository (empty when done): " app && [ -n "$app" ]; do
            read -r -e -p "  build .env for $app: " file
            envs+=("$app=$file")
        done
        if [ ${#envs[@]} -gt 0 ] && [ -z "$npmrc" ]; then
            npmrc_default=""
            for candidate in "$site/shared/.npmrc" "$site/.npmrc"; do
                if [ -n "$site" ] && [ -f "$candidate" ]; then
                    npmrc_default=$candidate
                    break
                fi
            done
            read -r -e -p ".npmrc for private packages, - for none${npmrc_default:+ [$npmrc_default]}: " npmrc
            npmrc=${npmrc:-$npmrc_default}
            [ "$npmrc" != "-" ] || npmrc=""
        fi
    fi
fi
[ -z "$npmrc" ] || [ -f "$npmrc" ] || fail "no such file: $npmrc"
for pair in "${envs[@]}"; do
    [[ "${pair%%=*}" =~ ^[a-z0-9-]+$ ]] && [ -f "${pair#*=}" ] || fail "build env $pair: expected APP=existing file"
done

registered=""
[ ! -f "$runner_dir/.runner" ] || registered=" (registered)"
cat <<SUMMARY

  repository  $repo
  branch      $branch
  workflow    .github/workflows/$workflow
  target      $target: label, $builds, $env_dir
  runner      $runner_dir$registered
  build env   ${envs[*]:-unchanged}
  npmrc       ${npmrc:-none}

SUMMARY
if [ "$assume_yes" = 0 ]; then
    [ -t 0 ] || fail "no terminal to confirm on; pass --yes"
    read -r -p "Set this up? [Y/n] " answer
    [[ "$answer" =~ ^([yY].*)?$ ]] || fail "stopped, nothing changed"
fi

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

printf 'repo=%s\nbranch=%s\nworkflow=%s\nrunner_dir=%s\n' "$repo" "$branch" "$workflow" "$runner_dir" > "$env_dir/setup.conf"
chown root:"$user" "$env_dir/setup.conf"
chmod 640 "$env_dir/setup.conf"

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
