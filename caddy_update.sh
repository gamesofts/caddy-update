#!/usr/bin/env bash
set -euo pipefail

# Updates Caddy from the Linux amd64 releases built by gamesofts/forwardproxy.
RELEASE_REPO="gamesofts/forwardproxy"
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

if [[ -n "$REQUESTED_VERSION" ]]; then
    RELEASE_TAG="caddy-$REQUESTED_VERSION"
    RELEASE_API="https://api.github.com/repos/$RELEASE_REPO/releases/tags/$RELEASE_TAG"
else
    RELEASE_API="https://api.github.com/repos/$RELEASE_REPO/releases/latest"
fi

if ! wget -q "$RELEASE_API" -O "$TMP_DIRECTORY/release.json"; then
    echo "error: Failed to get forwardproxy release information: $RELEASE_API" >&2
    exit 1
fi

# Both latest and by-tag API responses contain a single tag_name.
RELEASE_TAG="$(grep -m1 '"tag_name"' "$TMP_DIRECTORY/release.json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [[ ! "$RELEASE_TAG" =~ ^caddy-v2\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: Unexpected forwardproxy release tag: $RELEASE_TAG" >&2
    exit 1
fi
RELEASE_VERSION="${RELEASE_TAG#caddy-}"
if [[ -n "$REQUESTED_VERSION" && "$RELEASE_VERSION" != "$REQUESTED_VERSION" ]]; then
    echo "error: Release version does not match the requested version." >&2
    exit 1
fi
if [[ -z "$REQUESTED_VERSION" && "$RELEASE_VERSION" == "$CURRENT_VERSION" ]]; then
    echo "info: No new version. The current version of Caddy is $CURRENT_VERSION."
    exit 0
fi

ARCHIVE="caddy-$RELEASE_VERSION-linux-amd64.tar.gz"
DOWNLOAD_BASE="https://github.com/$RELEASE_REPO/releases/download/$RELEASE_TAG"
echo "Downloading Caddy $RELEASE_VERSION from $RELEASE_REPO"
if ! wget -q "$DOWNLOAD_BASE/$ARCHIVE" -O "$TMP_DIRECTORY/$ARCHIVE" ||
   ! wget -q "$DOWNLOAD_BASE/SHA256SUMS" -O "$TMP_DIRECTORY/SHA256SUMS"; then
    echo "error: Failed to download release archive or checksums." >&2
    exit 1
fi
(
    cd "$TMP_DIRECTORY"
    sha256sum -c SHA256SUMS
)
tar -xzf "$TMP_DIRECTORY/$ARCHIVE" -C "$TMP_DIRECTORY" caddy
if [[ ! -f "$TMP_DIRECTORY/caddy" ]]; then
    echo "error: Release archive does not contain caddy." >&2
    exit 1
fi
if ! "$TMP_DIRECTORY/caddy" list-modules | grep -Fxq 'http.handlers.forward_proxy' ||
   ! "$TMP_DIRECTORY/caddy" list-modules | grep -Fxq 'dns.providers.cloudflare'; then
    echo "error: Release binary is missing Naive forwardproxy or Cloudflare DNS module." >&2
    exit 1
fi
if [[ "$("$TMP_DIRECTORY/caddy" version | awk 'NR==1 {print $1}')" != "$RELEASE_VERSION" ]]; then
    echo "error: Downloaded Caddy version does not match the release tag." >&2
    exit 1
fi

install -m 755 "$TMP_DIRECTORY/caddy" /usr/bin/caddy

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

echo "info: Caddy $RELEASE_VERSION is installed from $RELEASE_REPO."
