#!/bin/bash
# Install MacKVM Linux client into ~/.local/share/mackvm and enable systemd user service.
set -euo pipefail

cd "$(dirname "$0")"

INSTALL_DIR="$HOME/.local/share/mackvm"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
DESKTOP_DIR="$HOME/.local/share/applications"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$SYSTEMD_DIR" "$DESKTOP_DIR" "$HOME/.local/state/mackvm"
cp -R mackvm_linux "$INSTALL_DIR/"

cat > "$BIN_DIR/mackvm-linux" <<'EOF'
#!/bin/bash
export PYTHONPATH="$HOME/.local/share/mackvm${PYTHONPATH:+:$PYTHONPATH}"
export DISPLAY="${DISPLAY:-:0}"
if [ -z "${XAUTHORITY:-}" ] && [ -f "/run/user/$(id -u)/gdm/Xauthority" ]; then
    export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
fi
exec python3 -m mackvm_linux "$@"
EOF
chmod +x "$BIN_DIR/mackvm-linux"

cat > "$DESKTOP_DIR/mackvm.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=MacKVM
Comment=MacKVM Ubuntu Controlled Client
Exec=$BIN_DIR/mackvm-linux --show
Icon=input-keyboard
Terminal=false
Categories=Utility;
EOF

cat > "$SYSTEMD_DIR/mackvm.service" <<EOF
[Unit]
Description=MacKVM Ubuntu X11 Controlled Client
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$BIN_DIR/mackvm-linux
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF

systemctl --user daemon-reload
systemctl --user enable mackvm.service
systemctl --user restart mackvm.service
sleep 2
systemctl --user --no-pager -l status mackvm.service || true
