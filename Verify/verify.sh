#!/bin/zsh
# 只在构建验证时用：编译并运行自测（Verify/test）和离屏渲染（Verify/render）。产物放在 $OUT（默认 /tmp 下的临时目录），
# 不进 MacKVM.app。用法：Verify/verify.sh [unit|loopback|bonjour|procs|render]...（不带参数 = unit loopback procs render）
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-$(mktemp -d /tmp/mackvm-verify.XXXXXX)}"
mkdir -p "$OUT"
LIB=(${(f)"$(ls Sources/*.swift Sources/UI/*.swift | grep -v '^Sources/main.swift$')"})
FLAGS=(-swift-version 5 -target arm64-apple-macos26.0)
steps=("$@")
(( ${#steps} )) || steps=(unit preview loopback procs render)

need_test=0; need_render=0
for s in $steps; do [[ $s == render ]] && need_render=1 || need_test=1; done
if (( need_test )); then
    echo "== 编译自测程序 → $OUT/mackvm-test"
    swiftc $FLAGS -o "$OUT/mackvm-test" $LIB Verify/test/main.swift
fi
if (( need_render )); then
    echo "== 编译离屏渲染程序 → $OUT/mackvm-render"
    swiftc $FLAGS -o "$OUT/mackvm-render" $LIB Verify/render/main.swift
fi

for s in $steps; do
    case $s in
    unit|loopback|bonjour|preview)
        echo "######## $s"
        MACKVM_HOME="$OUT/home-$s" "$OUT/mackvm-test" $s 2>>"$OUT/test-$s.log"
        ;;
    procs)
        echo "######## 两进程：配对握手 + 加密帧"
        rm -f "$OUT/inviter.txt"
        MACKVM_HOME="$OUT/home-i" "$OUT/mackvm-test" proc-inviter "$OUT/inviter.txt" >"$OUT/proc-inviter.out" 2>"$OUT/proc-inviter.log" &
        IPID=$!
        for _ in {1..50}; do [[ -s "$OUT/inviter.txt" ]] && break; sleep 0.1; done
        read -r _ PORT _ CODE < "$OUT/inviter.txt"
        echo "被控进程 pid $IPID，配对端口 $PORT，配对码 $CODE"
        MACKVM_HOME="$OUT/home-c" "$OUT/mackvm-test" proc-seeker "$PORT" "$CODE" 2>"$OUT/proc-seeker.log" && SRC=0 || SRC=$?
        wait $IPID && IRC=0 || IRC=$?
        cat "$OUT/proc-inviter.out"
        echo "主控进程退出码 $SRC，被控进程退出码 $IRC"
        (( SRC == 0 && IRC == 0 )) || exit 1
        ;;
    render)
        echo "######## 离屏渲染 → $OUT/render"
        mkdir -p "$OUT/render"
        "$OUT/mackvm-render" "$OUT/render" design 2>"$OUT/render.log"
        ;;
    esac
done
echo "全部产物：$OUT"
