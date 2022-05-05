VERSION="$(/usr/bin/caddy version | awk 'NR==1 {print substr($1,2)}')"
CURRENT_VERSION="v${VERSION#v}"

TMP_FILE="$(mktemp)"
if ! wget -q 'https://api.github.com/repos/caddyserver/caddy/releases/latest' -O "$TMP_FILE"; then
  "rm" "$TMP_FILE"
  echo 'error: Failed to get release list, please check your network.'
  exit 1
fi
RELEASE_LATEST="$(sed 'y/,/\n/' "$TMP_FILE" | grep 'tag_name' | awk -F '"' '{print substr($4,2)}')"
RELEASE_VERSION="v${RELEASE_LATEST#v}"
"rm" "$TMP_FILE"

if [[ "$RELEASE_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "info: No new version. The current version of Caddy is $CURRENT_VERSION ."
  exit 1
fi

DOWNLOAD_LINK="https://github.com/caddyserver/caddy/releases/download/$RELEASE_VERSION/caddy_${RELEASE_LATEST}_linux_amd64.tar.gz"
echo "Downloading Caddy archive: $DOWNLOAD_LINK"

TMP_DIRECTORY="$(mktemp -d)"
ZIP_FILE="${TMP_DIRECTORY}/caddy_${RELEASE_LATEST}_linux_amd64.tar.gz"

if ! wget -q "$DOWNLOAD_LINK" -O "$ZIP_FILE"; then
  echo 'error: Download failed! Please check your network or try again.'
  "rm" -r "$TMP_DIRECTORY"
  exit 1
fi

if ! tar -zxf "$ZIP_FILE" -C "$TMP_DIRECTORY"; then
  echo 'error: Caddy decompression failed.'
  "rm" -r "$TMP_DIRECTORY"
  exit 1
fi

if systemctl list-unit-files | grep -qw 'caddy.service'; then
  if [[ -n "$(pidof caddy)" ]]; then
    service caddy stop
    echo 'info: Stop the Caddy service.'
  fi
fi

install -m 755 "${TMP_DIRECTORY}/caddy" "/usr/bin/caddy"

"rm" -r "$TMP_DIRECTORY"
echo "info: Caddy $RELEASE_VERSION is installed."

service caddy start
echo 'info: Start the Caddy service.'