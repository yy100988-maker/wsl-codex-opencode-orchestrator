#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home/bin" "$TMP/fake-bin" "$TMP/project/.opencode"
cat > "$TMP/home/bin/opencode" <<'EOF'
#!/usr/bin/env bash
exec powershell.exe -File C:/Users/example/opencode.ps1 "$@"
EOF
chmod +x "$TMP/home/bin/opencode"

cat > "$TMP/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
cat <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.opencode/bin"
cat > "$HOME/.opencode/bin/opencode" <<'CLI'
#!/usr/bin/env bash
printf '1.18.18\n'
CLI
chmod +x "$HOME/.opencode/bin/opencode"
INSTALLER
EOF
chmod +x "$TMP/fake-bin/curl"

cat > "$TMP/project/.opencode/wsl-config.json" <<'EOF'
{"wsl":{"auto_install_opencode":true}}
EOF

output="$(HOME="$TMP/home" PATH="$TMP/home/bin:$TMP/fake-bin:$PATH" bash "$ROOT/scripts/ensure-opencode.sh" "$TMP/project/.opencode/wsl-config.json")"
jq -e '.ok == true and .action == "installed" and .version == "1.18.18"' <<<"$output" >/dev/null
test ! -e "$TMP/home/bin/opencode"
grep -Fqx 'export PATH="$HOME/.opencode/bin:$PATH"' "$TMP/home/.profile"
test -x "$TMP/home/.opencode/bin/opencode"
echo 'opencode bootstrap smoke ok'
