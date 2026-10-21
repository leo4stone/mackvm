#!/bin/bash
# 写 LaunchAgent 并（重新）装载。两台用的是同一份，不带任何参数：角色和对方都来自界面上的配对。
# 用法：install-agent.sh
# 可以在别的机器上通过 ssh 执行：ssh <主机名> 'bash -s' < install-agent.sh
#
# KeepAlive 只在异常退出（崩溃、非 0 退出码）时拉起：用户在菜单选「退出 MacKVM」时程序 exit(0)，
# launchd 就不再拉起，直到下次登录（RunAtLoad）或用户双击 MacKVM（程序会 kickstart 这个任务）。
set -euo pipefail

if [ $# -ne 0 ]; then
    echo "新版不再需要参数（收到：$*），已忽略" >&2
fi

LABEL="io.github.leo4stone.mackvm"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
EXE="$HOME/Applications/MacKVM.app/Contents/MacOS/MacKVM"
LOG="$HOME/Library/Logs/MacKVM.log"
DOMAIN="gui/$(id -u)"

[ -x "$EXE" ] || { echo "找不到 $EXE，先把 MacKVM.app 装到 ~/Applications" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$EXE</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST"

# bootout 是异步的：旧实例没彻底卸掉之前 bootstrap 会失败（Bootstrap failed: 5），所以先等它卸干净
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.5
    done
fi
launchctl bootstrap "$DOMAIN" "$PLIST"
sleep 1
launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =|program =" || true
