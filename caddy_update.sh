#!/usr/bin/env bash
set -euo pipefail

# Updates Caddy from the Linux amd64 releases built by gamesofts/forwardproxy.
RELEASE_REPO="gamesofts/forwardproxy"
INSTALLED_RELEASE_FILE="/var/lib/caddy-update/installed-release"
VERSION="$(/usr/bin/caddy version | awk 'NR==1 {print substr($1,2)}')"
CURRENT_VERSION="v${VERSION#v}"

REQUESTED_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "error: Please specify the correct version." >&2
                exit 1
            fi
            REQUESTED_VERSION="v${2#v}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -n "$REQUESTED_VERSION" && ! "$REQUESTED_VERSION" =~ ^v2\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: Invalid Caddy version: $REQUESTED_VERSION" >&2
    exit 1
fi

TMP_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TMP_DIRECTORY"' EXIT

# Newer releases have source-specific tags, for example:
# caddy-v2.11.7-naive-ead68e770834. A Caddy core version alone is not
# sufficient to decide whether the Naive forwardproxy plugin is current.
RELEASE_TAG=""
if [[ -n "$REQUESTED_VERSION" ]]; then
    # Choose the most recent release of the requested Caddy version,
    # including source-specific Naive builds. No jq/python dependency.
    RELEASE_LIST_API="https://api.github.com/repos/$RELEASE_REPO/releases?per_page=100"
    if ! wget -q "$RELEASE_LIST_API" -O "$TMP_DIRECTORY/releases.json"; then
        echo "error: Failed to list forwardproxy releases: $RELEASE_LIST_API" >&2
        exit 1
    fi
    while IFS= read -r candidate; do
        if [[ "$candidate" =~ ^caddy-(v2\.[0-9]+\.[0-9]+)(-naive-[0-9a-f]{12})?$ ]] \
            && [[ "${BASH_REMATCH[1]}" == "$REQUESTED_VERSION" ]]; then
            RELEASE_TAG="$candidate"
            break
        fi
    done < <(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "$TMP_DIRECTORY/releases.json" \
        | sed -E 's/.*"([^"]+)"$/\1/')

    if [[ -z "$RELEASE_TAG" ]]; then
        # Old versions may fall outside the most recent 100 releases.
        RELEASE_API="https://api.github.com/repos/$RELEASE_REPO/releases/tags/caddy-$REQUESTED_VERSION"
        if ! wget -q "$RELEASE_API" -O "$TMP_DIRECTORY/release.json"; then
            echo "error: No release found for Caddy $REQUESTED_VERSION" >&2
            exit 1
        fi
        RELEASE_TAG="$(grep -m1 '"tag_name"' "$TMP_DIRECTORY/release.json" \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    fi
else
    RELEASE_API="https://api.github.com/repos/$RELEASE_REPO/releases/latest"
    if ! wget -q "$RELEASE_API" -O "$TMP_DIRECTORY/release.json"; then
        echo "error: Failed to get forwardproxy release information: $RELEASE_API" >&2
        exit 1
    fi
    RELEASE_TAG="$(grep -m1 '"tag_name"' "$TMP_DIRECTORY/release.json" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

if [[ ! "$RELEASE_TAG" =~ ^caddy-(v2\.[0-9]+\.[0-9]+)(-naive-[0-9a-f]{12})?$ ]]; then
    echo "error: Unexpected forwardproxy release tag: $RELEASE_TAG" >&2
    exit 1
fi
RELEASE_VERSION="${BASH_REMATCH[1]}"
if [[ -n "$REQUESTED_VERSION" && "$RELEASE_VERSION" != "$REQUESTED_VERSION" ]]; then
    echo "error: Release version does not match the requested version." >&2
    exit 1
fi

# Store the installed release tag, not only the Caddy core version.
# On a first run without a tag record, reinstall once to pick up plugin
# updates even if 'caddy version' is unchanged.
INSTALLED_RELEASE="$(cat "$INSTALLED_RELEASE_FILE" 2>/dev/null || true)"
if [[ "$RELEASE_TAG" == "$INSTALLED_RELEASE" && "$RELEASE_VERSION" == "$CURRENT_VERSION" ]]; then
    echo "info: Already installed $RELEASE_TAG; no update needed."
    exit 0
fi

ARCHIVE="${RELEASE_TAG}-linux-amd64.tar.gz"
DOWNLOAD_BASE="https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG"
echo "Downloading $RELEASE_TAG from $RELEASE_REPO"
if ! wget -q "$DOWNLOAD_BASE/$ARCHIVE" -O "$TMP_DIRECTORY/$ARCHIVE"; then
    echo "error: Failed to download release archive." >&2
    exit 1
fi
tar -xzf "$TMP_DIRECTORY/$ARCHIVE" -C "$TMP_DIRECTORY" caddy

# Replace atomically: overwriting a running /usr/bin/caddy can fail with
# "Text file busy", while renaming a new executable into place is safe.
INSTALL_TEMP="$(mktemp /usr/bin/.caddy-update.XXXXXXXX)"
trap 'rm -rf "$TMP_DIRECTORY"; rm -f "$INSTALL_TEMP"' EXIT
install -m 755 "$TMP_DIRECTORY/caddy" "$INSTALL_TEMP"
mv -f "$INSTALL_TEMP" /usr/bin/caddy

if [[ ! -f "/lib/systemd/system/caddy.service" ]]; then
  cat >"/lib/systemd/system/caddy.service" <<'EOF'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
User=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/caddy
systemctl enable caddy.service
fi

mkdir -p "$(dirname "$INSTALLED_RELEASE_FILE")"
printf '%s\n' "$RELEASE_TAG" > "$INSTALLED_RELEASE_FILE"
echo "info: Installed $RELEASE_TAG from $RELEASE_REPO."
