#!/bin/bash
# Point this checkout at the repository that will publish it.
#
# The updater, the installer and the menu script all need to know where their
# own releases live. Rather than a build-time substitution that only works in
# CI, every one of those places reads a SUI_REPO variable whose default is the
# placeholder below -- this rewrites the defaults so a plain release build is
# already self-hosting.
#
#   ./setrepo.sh yourname/s-ui-mo
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <owner/repo>" >&2
    exit 1
fi

repo="$1"
if [[ ! "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "error: '$repo' is not an owner/repo pair" >&2
    exit 1
fi

cd "$(dirname "$0")"
count=0
# build-release.sh 必须在这个列表里：它把 PANEL_REPO 通过
# -X .../config.PanelRepo 注入二进制，默认值同样是 OWNER/REPO。
# 漏掉它的话，改完 config/config.go 的默认值也会在构建时被重新覆盖成占位符。
for f in install.sh s-ui.sh service/panel.go config/config.go build-release.sh Dockerfile; do
    [[ -f "$f" ]] || continue
    before=$(grep -c 'OWNER/REPO' "$f" || true)
    [[ "$before" -gt 0 ]] || continue
    sed -i.bak "s|OWNER/REPO|${repo}|g" "$f"
    rm -f "$f.bak"
    count=$((count + before))
    echo "  $f  ($before)"
done

echo "pointed $count reference(s) at ${repo}"
case "$repo" in
*/s-ui-mo | */s-ui) ;;
*) echo "note: install.sh and the updater assume the default branch is 'main' and the script is at its root." ;;
esac
