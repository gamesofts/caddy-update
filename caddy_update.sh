VERSION="$(/usr/bin/caddy version | awk 'NR==1 {print substr($1,2)}')"
CURRENT_VERSION="v${VERSION#v}"

TMP_FILE="$(mktemp)"
if ! wget -q 'https://api.github.com/repos/caddyserver/caddy/releases/latest' -O "$TMP_FILE"; then
  "rm" "$TMP_FILE"
  echo 'error: Failed to get release list, please check your network.'
  exit 1
fi
RELEASE_LATEST="$(sed 'y/,/\n/' "$TMP_FILE" | grep 'tag_name' | awk -F '"' '{print substr($4,2)}')"
"rm" "$TMP_FILE"

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --version)
            shift
            if [[ -z "$1" || "$1" == --* ]]; then
                echo "Error: Please specify the correct version."
                exit 1
            fi
            RELEASE_LATEST="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

RELEASE_VERSION="v${RELEASE_LATEST#v}"
if [[ "$RELEASE_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "info: No new version. The current version of Caddy is $CURRENT_VERSION ."
  exit 1
fi

DOWNLOAD_LINK="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fcloudflare"
echo "Downloading Caddy archive: $DOWNLOAD_LINK"

TMP_DIRECTORY="$(mktemp -d)"
CADDY_FILE="${TMP_DIRECTORY}/caddy_${RELEASE_LATEST}"

if ! wget -q "$DOWNLOAD_LINK" -O "$CADDY_FILE"; then
  echo 'error: Download failed! Please check your network or try again.'
  "rm" -r "$TMP_DIRECTORY"
  exit 1
fi

install -m 755 "${CADDY_FILE}" "/usr/bin/caddy"

"rm" -r "$TMP_DIRECTORY"
echo "info: Caddy $RELEASE_VERSION is installed."
