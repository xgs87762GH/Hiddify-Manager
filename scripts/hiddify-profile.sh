# 为交互式 bash 加载 hiddify 命令补全
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]] && [ -f /opt/hiddify-manager/scripts/hiddify-completion.bash ]; then
    . /opt/hiddify-manager/scripts/hiddify-completion.bash
fi
