cd $(dirname -- "$0")
source ./utils.sh

# 步骤耗时统计：每步之后输出 "[timing] <步骤> <毫秒>（总计 <毫秒>）"，
# 便于定位 apply 过程中的慢环节。
_timing_start=${EPOCHREALTIME//[.,]/}
_timing_last=$_timing_start
function timing() {
    local now=${EPOCHREALTIME//[.,]/}
    printf '[timing] %-26s %7d ms (total %d ms)\n' "$1" $(((now - _timing_last) / 1000)) $(((now - _timing_start) / 1000))
    _timing_last=$now
}

activate_python_venv
ensure_hiddify_data_dirs
timing "虚拟环境与数据目录"


remove_old_server_templates() {
    local base=/opt/hiddify-manager/services
    local t

    # 删除模板及其渲染产物（foo.conf.j2 -> foo.conf）
    remove_template_pair() { rm -f -- "$1" "${1%.j2}"; }

    # 这些目录下的所有 *.j2 及对应渲染文件
    local -a dirs=(
        "$base/nginx"
        "$base/haproxy"
        "$base/firewall"
        "$base/wireguard"
        "$base/telegram/telemt"
        "$base/rust-rpxy-l4"
        "$base/xray/configs"
        "$base/hiddify-core/configs"
    )
    while IFS= read -r -d '' t; do
        remove_template_pair "$t"
    done < <(find "${dirs[@]}" -type f -name '*.j2' -print0 2>/dev/null)
}

remove_old_server_templates
# 已废弃服务的模板（它们自身的文件由 remove_deprecated.sh 处理）。这里只删 .j2：
# telegram 的 install.sh 和 run.sh 现在是普通脚本，不能被渲染覆盖。
rm -rf /opt/hiddify-manager/services/v2ray /opt/hiddify-manager/services/telegram/{erlang,orig,python,tgo}
rm -f /opt/hiddify-manager/services/telegram/install.sh.j2 /opt/hiddify-manager/services/telegram/run.sh.j2
timing "清理旧模板"


if ! is_valid_current_json /opt/hiddify-manager/data/current.json; then
    error "data/current.json 内容不合法，已跳过应用配置"
    exit 1
fi
# 证书：面板根据数据库写入 data/cert —— 对于没有证书的域名生成自签证书
#（HAProxy 没有证书无法启动），被移除域名的证书文件则删除。
# 正式证书由面板自行申请（hiddifypanel/acme）。
ensure_cert_dir
hiddify-panel-cli export-certificates || warning "无法从面板导出证书"
timing "证书"

ensure_generated_permissions
dump_server_configs || {
    echo "导出服务端配置到 $HIDDIFY_GENERATED 失败" >&2
    exit 1
}
ensure_generated_permissions
timing "导出服务端配置"

# 其余 .j2 模板（run.sh、firewall、ssh 等）—— 不属于 dump-server-configs 的输出。
# 使用虚拟环境里的 python：脚本自带的 shebang 在部分安装布局下不可靠。
python /opt/hiddify-manager/scripts/common/jinja.py $MODE
jinja_rc=$?
timing "渲染 .j2 模板"
printf '[timing] 替换变量总计：%d ms\n' $(((${EPOCHREALTIME//[.,]/} - _timing_start) / 1000))
exit $jinja_rc
