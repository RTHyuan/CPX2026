#!/bin/zsh
set -eu
if [[ -z ${DEEPSEEK_API_KEY:-} ]]; then
    read -rs 'DEEPSEEK_API_KEY?请输入项目测试 Key（隐藏输入，仅在本进程有效）：'
    printf '\n'
    export DEEPSEEK_API_KEY
fi
[[ -n $DEEPSEEK_API_KEY ]] || exit 1
exec python3 "${0:A:h:h}/Proxy/server.py" "$@"
