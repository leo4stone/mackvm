#!/bin/bash
# 把本机仓库的 linux/ 部署到 Ubuntu 设备，在远端跑单元测试、安装并重启 systemd --user 服务。
# 用法：deploy-linux.sh [ssh 主机名]
#   主机名也可以写在 local.env 的 MACKVM_LINUX_HOST（见 local.env.example）。
set -euo pipefail
cd "$(dirname "$0")"
[ -f local.env ] && source local.env
HOST="${1:-${MACKVM_LINUX_HOST:-}}"
if [ -z "$HOST" ]; then
    echo "用法：$0 <ssh 主机名>（或在 local.env 里设 MACKVM_LINUX_HOST）" >&2
    exit 1
fi

echo "== 上传 linux/ 到 $HOST"
ssh "$HOST" 'rm -rf /tmp/mackvm-linux-deploy && mkdir -p /tmp/mackvm-linux-deploy'
COPYFILE_DISABLE=1 tar -C "$PWD/linux" -cf - . | ssh "$HOST" 'tar -C /tmp/mackvm-linux-deploy -xf -'

echo "== 在 $HOST 运行单元测试"
ssh "$HOST" 'python3 /tmp/mackvm-linux-deploy/test_linux.py'

echo "== 在 $HOST 安装并重启 mackvm.service"
ssh "$HOST" 'bash /tmp/mackvm-linux-deploy/install-linux.sh && rm -rf /tmp/mackvm-linux-deploy'

echo "== 检查最近日志"
ssh "$HOST" 'tail -n 20 ~/.local/state/mackvm/mackvm.log 2>/dev/null || true'
