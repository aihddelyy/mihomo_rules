#!/bin/sh
# Zashboard IPv6 更新脚本 (最终多版本) - 兼容 OpenWrt BusyBox

# 确保脚本使用 LF 换行符
sed -i 's/\r//g' "$0" 2>/dev/null

# --- 配置 ---
CONFIG_FILE="/etc/nikki/run/ui/zashboard-settings-bak.json" # 保持使用备份作为源文件
OUTPUT_FILE_MOBILE="/etc/nikki/run/ui/zashboard-settings-mobile.json"
OUTPUT_FILE_PC="/etc/nikki/run/ui/zashboard-settings-pc.json"
TEMP_DIR="/tmp/zaboard_update"

# --- 检查依赖项 ---
if ! command -v jq >/dev/null 2>&1; then echo "错误: 找不到 'jq' 命令。请先运行 'opkg install jq' 安装。"; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then echo "错误: 找不到配置文件 $CONFIG_FILE 。请检查路径是否正确。"; exit 1; fi

# --- 准备工作 ---
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
echo "--- 准备开始执行任务 ---"
TEMP_USERS="$TEMP_DIR/online_users_complete.txt"
TEMP_IPV4="$TEMP_DIR/ipv4_list_final.tmp"
TEMP_IPV6="$TEMP_DIR/ipv6_list_final.tmp"
FILE_JQ_FILTER="$TEMP_DIR/update_filter.jq"

# =======================================================
# 阶段 1 & 2: 数据提取与字典构造 (只需运行一次)
# =======================================================
echo "1. 正在获取并合并实时在线用户数据..."

# 提取 MAC/IPv4/IPv6
ip neigh show | grep -E 'REACHABLE|STALE|DELAY|PERMANENT' | grep 'lladdr' | awk '
{
    ip_addr = $1
    mac_addr = ""
    for (i=1; i<=NF; i++) {
        if ($i == "lladdr") { mac_addr = tolower($(i+1)); break }
    }
    if (mac_addr != "") {
        if (ip_addr ~ /([0-9]{1,3}\.){3}[0-9]{1,3}/) {
            print mac_addr, ip_addr >> "'"$TEMP_IPV4"'"
        } else if (ip_addr ~ /:/ && ip_addr ~ /^24/) {
            print mac_addr, ip_addr >> "'"$TEMP_IPV6"'"
        }
    }
}
'

# 合并 IPv4 和 IPv6 列表
awk 'FNR==NR { a[$1]=$2; next } { if ($1 in a) { a[$1] = a[$1] " " $2 } else { a[$1] = $2 } } END { for (mac in a) { print mac, a[mac] } }' \
    <(sort -u "$TEMP_IPV6") <(sort -u "$TEMP_IPV4") | sort | \
awk '
{
    mac = $1
    v4 = ""
    v6_list = ""
    is_v4 = ($2 ~ /([0-9]{1,3}\.){3}[0-9]{1,3}/)
    if (is_v4) { v4 = $2; start_idx = 3 } else { start_idx = 2 }
    for (i=start_idx; i<=NF; i++) { v6_list = v6_list " " $i }
    print mac, v4, v6_list
}
' | sed 's/  */ /g' | sed 's/^ //g' | sort > "$TEMP_USERS"

echo "  -> 实时数据提取完成。"

# 构造 JSON 字典字符串
echo "2. 正在构造 JQ 字典..."
V4V6_MAP=$(
    awk ' $2 != "" && $3 != "" {v4 = $2; v6_list = ""; for (i=3; i<=NF; i++) {if (i > 3) {v6_list = v6_list ", "}; v6_list = v6_list "\"" $i "\""}; printf "\"%s\": [%s],", v4, v6_list} ' "$TEMP_USERS" | sed 's/,$//'
)
V4V6_MAP="{$V4V6_MAP}"

IPV4_LABEL_MAP_CONTENT=$(
    jq -r '.["config/source-ip-label-list"] | (fromjson? // [])[] | select(.key | contains(".") and (contains(":") | not)) | "\"" + .key + "\":\"" + .label + "\""' "$CONFIG_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//'
)
IPV4_LABEL_MAP_CONTENT="{$IPV4_LABEL_MAP_CONTENT}"

# JQ 过滤器定义 (仅需定义一次)
cat << 'EOF_JQ' > "$FILE_JQ_FILTER"
  ($ENV.V4V6_MAP_FINAL | fromjson? // {}) as $v4v6map |
  ($ENV.IPV4_LABEL_MAP_FINAL | fromjson? // {}) as $v4labelmap |
  .["config/source-ip-label-list"] | (try (fromjson) catch ([])) as $original_list |
  ( $v4labelmap | to_entries | map({label: .value, ipv6_list: ($v4v6map[.key] | if . == null then [] else . end)}) | (reduce .[] as $item ({}; .[$item.label] += $item.ipv6_list))) as $new_ipv6_by_label |
  ( ($original_list | 
      reduce .[] as $item ({result: [], updated_labels: {}}; 
        . as $state |
        if $item.key | contains(":") then
            ($new_ipv6_by_label[$item.label] | if . == null then [] else . end) as $new_list |
            ($state.updated_labels[$item.label] // 0) as $current_count |
            if ($current_count < ($new_list | length)) then
                ($item | .key = $new_list[$current_count]) as $updated_item |
                {result: ($state.result + [$updated_item]), updated_labels: ($state.updated_labels + {($item.label): ($current_count + 1)})}
            else
                {result: ($state.result + [$item]), updated_labels: $state.updated_labels}
            end
        else
            {result: ($state.result + [$item]), updated_labels: $state.updated_labels}
        end
      ) | .result
    )
  ) | (if . == null then [] else . end) | tojson
EOF_JQ

# 运行 JQ 流程
echo "3. 正在运行 JQ 流程..."
V4V6_MAP_FINAL="$V4V6_MAP" IPV4_LABEL_MAP_FINAL="$IPV4_LABEL_MAP_CONTENT" \
NEW_JSON_LIST=$(jq -r -f "$FILE_JQ_FILTER" "$CONFIG_FILE") 

if [ -z "$NEW_JSON_LIST" ] || [ "$NEW_JSON_LIST" = "null" ]; then
    echo "🚨 警告: JQ 过滤器输出无效或为空。强制回退到 '[]'。"
    NEW_JSON_LIST="[]"
fi

echo "  -> JQ 已成功生成新的列表内容。"


# =======================================================
# 阶段 4: 替换并生成 MOBILE 版本 (zashboard-settings-mobile.json)
# =======================================================
echo "4. 生成 MOBILE 版本 ($OUTPUT_FILE_MOBILE)..."

# 1. 替换 'config/source-ip-label-list' (与之前版本逻辑相同)
ESCAPED_CONTENT=$(printf '%s' "$NEW_JSON_LIST" | awk '{ gsub(/"/, "\\\""); gsub(/\\/, "\\\\"); gsub(/\//, "\\/"); print }')
sed "s/  \"config\/source-ip-label-list\": \".*\",/  \"config\/source-ip-label-list\": \"$ESCAPED_CONTENT\",/" "$CONFIG_FILE" > "$OUTPUT_FILE_MOBILE.tmp"

# 2. 修改 Mobile 特有配置: import-settings-url
sed -i 's/"config\/import-settings-url": "\/ui\/zashboard-settings.json",/"config\/import-settings-url": "\/ui\/zashboard-settings-mobile.json",/' "$OUTPUT_FILE_MOBILE.tmp"

# 3. 最终写入
mv "$OUTPUT_FILE_MOBILE.tmp" "$OUTPUT_FILE_MOBILE"
echo "  ✅ Mobile 版本生成完毕。"

# =======================================================
# 阶段 5: 替换并生成 PC 版本 (zashboard-settings-pc.json)
# =======================================================
echo "5. 生成 PC 版本 ($OUTPUT_FILE_PC)..."

# 1. 替换 'config/source-ip-label-list' (从原始文件再次开始替换)
ESCAPED_CONTENT=$(printf '%s' "$NEW_JSON_LIST" | awk '{ gsub(/"/, "\\\""); gsub(/\\/, "\\\\"); gsub(/\//, "\\/"); print }')
sed "s/  \"config\/source-ip-label-list\": \".*\",/  \"config\/source-ip-label-list\": \"$ESCAPED_CONTENT\",/" "$CONFIG_FILE" > "$OUTPUT_FILE_PC.tmp"

# 2. 修改 PC 特有配置: import-settings-url
sed -i 's/"config\/import-settings-url": "\/ui\/zashboard-settings.json",/"config\/import-settings-url": "\/ui\/zashboard-settings-pc.json",/' "$OUTPUT_FILE_PC.tmp"

# 3. 修改 PC 特有配置: use-connecticon-card
# 注意: 替换 true/false 字符串时，必须确保 sed 命令中的转义正确，这里我们直接替换整行
sed -i 's/"config\/use-connecticon-card": "true",/"config\/use-connecticon-card": "false",/' "$OUTPUT_FILE_PC.tmp"

# 4. 最终写入
mv "$OUTPUT_FILE_PC.tmp" "$OUTPUT_FILE_PC"
echo "  ✅ PC 版本生成完毕。"

# =======================================================
# 阶段 6: 清理与完成
# =======================================================
rm -rf "$TEMP_DIR"

echo "--- 任务完成 ---"
echo "✅ 新的配置已保存到 $OUTPUT_FILE_MOBILE 和 $OUTPUT_FILE_PC"
echo "🎉 脚本运行完毕，请确保 zashboard 服务的导入设置路径已经指向了这两个新文件。"