#!/bin/bash
# 把本机签好名的 ~/Applications/MacKVM.app 复制到另一台 Mac，验签，并用 install-agent.sh 装好那边的 LaunchAgent。
# 用法：deploy-remote.sh [ssh 主机名]
#   主机名也可以写在 local.env 的 MACKVM_DEPLOY_HOST（见 local.env.example）。
# 角色、对方是谁都来自界面上的配对，不需要传别的参数。
# 远端机器的登录钥匙串在 SSH 会话里是锁的，无法在那边签名，所以只复制本机编译好的产物，不在远端重新编译。
set -euo pipefail
cd "$(dirname "$0")"
[ -f local.env ] && source local.env
HOST="${1:-${MACKVM_DEPLOY_HOST:-}}"
if [ -z "$HOST" ]; then
    echo "用法：$0 <ssh 主机名>（或在 local.env 里设 MACKVM_DEPLOY_HOST）" >&2
    exit 1
fi

codesign --verify --strict "$HOME/Applications/MacKVM.app"
ssh "$HOST" 'mkdir -p ~/Applications && rm -rf ~/Applications/MacKVM.app'
tar -C "$HOME/Applications" -cf - MacKVM.app | ssh "$HOST" 'tar -C ~/Applications -xf -'
ssh "$HOST" 'xattr -cr ~/Applications/MacKVM.app && codesign --verify --strict --verbose=2 ~/Applications/MacKVM.app'
ssh "$HOST" "bash -s" < install-agent.sh
