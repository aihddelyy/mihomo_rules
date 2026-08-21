#!/bin/sh
# Zashboard IPv6 更新脚本 (最终版 25.0 - EUI64 保留优化版)
# - 修复了 Shell 兼容性问题。
# - 实现了特殊地址（如 eui64 格式或非 '24' 开头地址）的保留逻辑：
#   对于旧的 IPv6 记录，如果它未能被新的 '24' 地址替换，则不删除它，而是直接保留。

# 确保脚本使用 LF 换行符
sed -i 's/\r//g' "$0" 2>/dev/null

# --- 配置 ---
CONFIG_FILE="/etc/nikki/run/ui/zashboard-settings-bak.json"
ORIGIN_FILE="/etc/nikki/run/ui/zashboard-settings-origin.json"
OUTPUT_FILE_GENERAL="/etc/nikki/run/ui/zashboard-settings.json"
OUTPUT_FILE_MOBILE="/etc/nikki/run/ui/zashboard-settings-mobile.json"
OUTPUT_FILE_PC="/etc/nikki/run/ui/zashboard-settings-pc.json"
TEMP_DIR="/tmp/zaboard_update"

# --- 检查依赖项 ---
if ! command -v jq >/dev/null 2>&1; then echo "错误: 找不到 'jq' 命令。请先运行 'opkg install jq' 安装。"; exit 1; fi
if [ ! -f "$CONFIG_FILE" ]; then echo "错误: 找不到配置文件 $CONFIG_FILE 。请检查路径是否正确。"; exit 1; fi

# --- ID 生成函数 ---
generate_id() {
    printf "z%s%s" "$(date +%N)" "$(head /dev/urandom | tr -dc a-f0-9 | head -c 8 2>/dev/null)"
}

# --- 准备工作 ---
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
echo "--- 准备开始执行任务 ---"

# --- 1. 备份原始文件 ---
echo "  -> 备份 $CONFIG_FILE 到 $ORIGIN_FILE"
cp "$CONFIG_FILE" "$ORIGIN_FILE"

TEMP_MAC_V4="$TEMP_DIR/mac_ipv4.map"
TEMP_MAC_V6="$TEMP_DIR/mac_ipv6.map"
FILE_JQ_FILTER="$TEMP_DIR/update_filter.jq" 
FILE_REMAINING="$TEMP_DIR/remaining_to_add.json" 
FILE_ITEM_CREATOR="$TEMP_DIR/item_creator.jq"
FILE_NEW_ITEMS_RAW="$TEMP_DIR/new_items_raw.json"

# =======================================================
# 阶段 1: 数据提取并分类 (MAC -> IP)
# =======================================================
echo "1. 正在获取并分离 MAC/IP 数据..."
ip neigh show | grep -E 'REACHABLE|STALE|DELAY|PERMANENT' | grep 'lladdr' | awk '
{
    ip_addr = $1
    mac_addr = ""
    for (i=1; i<=NF; i++) {
        if ($i == "lladdr") { mac_addr = tolower($(i+1)); break }
    }
    if (mac_addr != "") {
        if (ip_addr ~ /([0-9]{1,3}\.){3}[0-9]{1,3}/) {
            print mac_addr, ip_addr >> "'"$TEMP_MAC_V4"'"
        } 
        # 扩大 IPv6 捕获范围：匹配所有以 '24' 开头的 IPv6 地址
        else if (ip_addr ~ /:/ && ip_addr ~ /^24/) { 
            print mac_addr, ip_addr >> "'"$TEMP_MAC_V6"'"
        }
    }
}
'
echo "  -> MAC -> IPv4 列表完成：$(wc -l < "$TEMP_MAC_V4") 条记录"

# 鲁棒性检查：确保 IPv6 文件存在，避免后续 AWK 报错
if [ ! -f "$TEMP_MAC_V6" ]; then
    touch "$TEMP_MAC_V6"
fi

echo "  -> MAC -> IPv6 列表完成：$(wc -l < "$TEMP_MAC_V6") 条记录"


# =======================================================
# 阶段 2: JQ 字典构造 (IPv4 -> [IPv6s])
# =======================================================
echo "2. 正在构造 JQ 字典 (IPv4 -> [IPv6s])..."
# 2.1 构造 V4V6_MAP (IPv4 -> [IPv6s])
V6_BY_MAC=$(awk '
    {
        mac=$1; 
        v6_list[mac]=(v6_list[mac]? v6_list[mac] ", " : "") "\"" $2 "\""
    } 
    END{
        for (mac in v6_list) {print mac, v6_list[mac]}
    }
' "$TEMP_MAC_V6")

V4V6_MAP=$(
    awk '
    FNR==NR { 
        mac=$1; 
        v6_map[mac] = "[" substr($0, length(mac) + 2) "]" 
        next 
    }
    { 
        mac = $1; 
        v4 = $2; 
        if (mac in v6_map) {
            printf "\"%s\": %s,", v4, v6_map[mac]
        }
    }
    ' <(echo "$V6_BY_MAC") "$TEMP_MAC_V4" | sed 's/,$//'
)
V4V6_MAP="{$V4V6_MAP}"

# 2.2 IPV4_LABEL_MAP_CONTENT (从配置文件提取 IPv4: Label)
IPV4_LABEL_MAP_CONTENT=$(
    jq -r '.["config/source-ip-label-list"] | (fromjson? // [])[] | select(.key | contains(".") and (contains(":") | not)) | "\"" + .key + "\":\"" + .label + "\""' "$CONFIG_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//'
)
IPV4_LABEL_MAP_CONTENT="{$IPV4_LABEL_MAP_CONTENT}"

echo "  -> 字典构造完成。"


# =======================================================
# 阶段 3: JQ 严格同步逻辑 (更新/保留/删除)
# =======================================================
echo "3. 正在运行 JQ 严格同步流程 (更新/保留/删除/计算新增)..."

# JQ 核心逻辑定义到文件 (已修改 2.2 逻辑)
cat << 'EOF_JQ_FILTER' > "$FILE_JQ_FILTER"
($ENV.V4V6_MAP_FINAL | fromjson? // {}) as $v4v6map |
($ENV.IPV4_LABEL_MAP_FINAL | fromjson? // {}) as $v4labelmap |
.["config/source-ip-label-list"] | (try (fromjson) catch ([])) as $original_list |

# 1. 构造 {label: [v6_list]} 的字典
($v4labelmap | to_entries | map({label: .value, ipv6_list: ($v4v6map[.key] | if . == null then [] else . end)}) | (reduce .[] as $item ({}; .[$item.label] += $item.ipv6_list))) as $new_ipv6_by_label |

# 2. Reduce: 严格替换/删除逻辑
( $original_list | 
  reduce .[] as $item ({result: [], v6_used_counts: {}}; 
    . as $state |
    if $item.key | contains(".") then
        # 2.1. IPv4 记录：保留
        {result: ($state.result + [$item]), v6_used_counts: $state.v6_used_counts}
    elif $item.key | contains(":") then
        # 2.2. IPv6 记录：尝试替换
        ($new_ipv6_by_label[$item.label] | if . == null then [] else . end) as $new_list |
        ($state.v6_used_counts[$item.label] // 0) as $current_count |
        
        if ($current_count < ($new_list | length)) then
            # 找到新地址替换：替换 key 并记录使用次数
            ($item | .key = $new_list[$current_count]) as $updated_item |
            {result: ($state.result + [$updated_item]), v6_used_counts: ($state.v6_used_counts + {($item.label): ($current_count + 1)})}
        else
            # 未找到新地址替换 (新列表用尽或为空)，执行保留/删除判断
            if ($item.key | startswith("24")) then
                # 如果旧地址是 '24' 开头的公网地址，但没有新的地址替换它，则删除
                $state
            else
                # 如果旧地址不是 '24' 开头 (如 EUI-64, FE80 链路本地等)，且没有新地址替换它，则保留
                {result: ($state.result + [$item]), v6_used_counts: $state.v6_used_counts}
            end
        end
    else
        # 2.3. 其他未知格式记录：保留
        {result: ($state.result + [$item]), v6_used_counts: $state.v6_used_counts}
    end
  )
) as $intermediate_result |

# 3. 计算剩余需要新增的地址 (未被上面的替换逻辑使用的新 V6 地址)
( [ $new_ipv6_by_label | to_entries[] | 
    .value as $new_list |
    .key as $label |
    ($intermediate_result.v6_used_counts[$label] // 0) as $used_count |
    if ($used_count < ($new_list | length)) then
        ($new_list | .[$used_count:]) | 
        map({"key": ., "label": $label})
    else
        empty
    end
  ] | flatten // [] 
) as $remaining_v6_list |

if $output_type == "processed" then
    $intermediate_result.result
elif $output_type == "remaining" then
    $remaining_v6_list // []
else
    empty
end
EOF_JQ_FILTER

# --- JQ 调用 1/2 ---
PROCESSED_LIST_JSON=$(V4V6_MAP_FINAL="$V4V6_MAP" IPV4_LABEL_MAP_FINAL="$IPV4_LABEL_MAP_CONTENT" \
jq -c -r --arg output_type "processed" -f "$FILE_JQ_FILTER" "$CONFIG_FILE")

V4V6_MAP_FINAL="$V4V6_MAP" IPV4_LABEL_MAP_FINAL="$IPV4_LABEL_MAP_CONTENT" \
jq -c -r --arg output_type "remaining" -f "$FILE_JQ_FILTER" "$CONFIG_FILE" > "$FILE_REMAINING"

if [ -z "$PROCESSED_LIST_JSON" ]; then PROCESSED_LIST_JSON="[]"; fi
echo "  -> JQ 流程完成。已处理列表长度: $(echo "$PROCESSED_LIST_JSON" | jq 'length' 2>/dev/null)"


# =======================================================
# 阶段 4: Bash 循环新增项目
# =======================================================

echo "4. 正在构造待新增的 IPv6 地址记录..."
# 尝试从现有配置中提取一个 IPv6 记录作为模板
ITEM_TEMPLATE_RAW=$(jq -r '.["config/source-ip-label-list"] | (fromjson? // [])[] | select(.key | contains(":")) | del(.key, .label, .id)' "$CONFIG_FILE" 2>/dev/null | head -n 1)

# 确保提取的模板是否为空或非 JSON，如果不是则使用空 JSON 对象 '{}'
if [ -z "$ITEM_TEMPLATE_RAW" ] || ! echo "$ITEM_TEMPLATE_RAW" | jq empty 2>/dev/null; then
    ITEM_TEMPLATE_RAW="{}"
fi

# 将 JQ 逻辑写入文件
cat << EOF_ITEM_CREATOR > "$FILE_ITEM_CREATOR"
{
    key: .key,
    label: .label,
    id: \$id
} + (\$template | fromjson? // {})
EOF_ITEM_CREATOR

# 1. 确保临时文件存在且为空
> "$FILE_NEW_ITEMS_RAW"

if [ -f "$FILE_REMAINING" ] && [ "$(jq 'length' "$FILE_REMAINING" 2>/dev/null)" -gt 0 ]; then
    
    # 将新增的 JSON 对象直接输出到文件
    jq -c -r '.[]' "$FILE_REMAINING" | while IFS= read -r item_json; do
        NEW_ID=$(generate_id) 
        
        # 使用 jq -f 和 --argjson 安全地构建新的 JSON 对象
        NEW_ITEM=$(echo "$item_json" | jq -f "$FILE_ITEM_CREATOR" --arg id "$NEW_ID" --argjson template "$ITEM_TEMPLATE_RAW")

        if [ -n "$NEW_ITEM" ]; then
            printf "%s\n" "$NEW_ITEM" >> "$FILE_NEW_ITEMS_RAW"
        fi
    done
fi

NEW_ITEM_COUNT=$(wc -l < "$FILE_NEW_ITEMS_RAW")

echo "  -> 成功构造 $NEW_ITEM_COUNT 个 IPv6 地址记录。"


# =======================================================
# 阶段 5: 最终列表合并与文件生成
# =======================================================
echo "5. 正在合并最终列表并生成配置文件..."

# 从文件而不是 Bash 变量中读取新增的 JSON 对象列表
NEW_JSON_LIST=$(
    jq -s -r --argjson processed "$PROCESSED_LIST_JSON" '
        ($processed | if . == null then [] else . end) as $base_list |
        (if . == null then [] else . end) as $new_list |
        $base_list + $new_list | tojson
    ' "$FILE_NEW_ITEMS_RAW"
)

if [ -z "$NEW_JSON_LIST" ] || [ "$NEW_JSON_LIST" = "null" ]; then
    echo "🚨 严重警告: 最终列表合并失败。强制回退到 '[]'。"
    NEW_JSON_LIST="[]"
fi

TOTAL_LIST_LENGTH=$(echo "$NEW_JSON_LIST" | jq 'length' 2>/dev/null)
echo "  -> 最终列表总长度: $TOTAL_LIST_LENGTH"

# --- 准备 IP 列表替换内容 ---
ESCAPED_CONTENT=$(printf '%s' "$NEW_JSON_LIST" | awk '{ gsub(/"/, "\\\""); gsub(/\\/, "\\\\"); gsub(/\//, "\\/"); print }')


# 5.1 生成 通用版本 (zashboard-settings.json)
echo "  -> 正在生成 通用版本 ($OUTPUT_FILE_GENERAL)..."
# 1. 替换 IP 列表内容 (使用 # 分隔符)
sed "s#  \"config\/source-ip-label-list\": \".*\",#  \"config\/source-ip-label-list\": \"$ESCAPED_CONTENT\",#" "$CONFIG_FILE" > "$OUTPUT_FILE_GENERAL.tmp"

# 2. 替换导入 URL 为通用版自身 (使用 # 分隔符)
GENERAL_URL_TARGET="/ui/zashboard-settings.json"
sed -i "s#\"config\/import-settings-url\": \".*\",#\"config\/import-settings-url\": \"$GENERAL_URL_TARGET\",#" "$OUTPUT_FILE_GENERAL.tmp"
mv "$OUTPUT_FILE_GENERAL.tmp" "$OUTPUT_FILE_GENERAL"

echo "  ✅ 通用版本生成完毕。"


# 5.2 生成 Mobile 版本 (zashboard-settings-mobile.json)
MOBILE_URL_TARGET="/ui/zashboard-settings-mobile.json"
echo "  -> 正在生成 Mobile 版本 ($OUTPUT_FILE_MOBILE)..."
cp "$OUTPUT_FILE_GENERAL" "$OUTPUT_FILE_MOBILE.tmp" # 从通用版本复制
# 替换导入 URL 为 Mobile 版自身 (使用 # 分隔符)
sed -i "s#\"config\/import-settings-url\": \".*\",#\"config\/import-settings-url\": \"$MOBILE_URL_TARGET\",#" "$OUTPUT_FILE_MOBILE.tmp"
# 替换 Mobile 专用配置 (使用 # 分隔符)
sed -i 's#\"config\/use-connecticon-card\": \".*\",#\"config\/use-connecticon-card\": \"true\",#' "$OUTPUT_FILE_MOBILE.tmp"
# 替换 Mobile 连接显示样式为 card (使用 # 分隔符)
sed -i 's#\"config\/connection-display-style\": \".*\",#\"config\/connection-display-style\": \"card\",#' "$OUTPUT_FILE_MOBILE.tmp"
# 替换 Mobile 连接排序方式为 connectTime (使用 # 分隔符)
sed -i 's#\"config\/connection-sort-type\": \".*\",#\"config\/connection-sort-type\": \"connectTime\",#' "$OUTPUT_FILE_MOBILE.tmp"
# 替换 Mobile 连接排序方向为 desc (使用 # 分隔符)
sed -i 's#\"config\/connection-sort-direction\": \".*\",#\"config\/connection-sort-direction\": \"desc\",#' "$OUTPUT_FILE_MOBILE.tmp"
mv "$OUTPUT_FILE_MOBILE.tmp" "$OUTPUT_FILE_MOBILE"
echo "  ✅ Mobile 版本生成完毕。"


# 5.3 生成 PC 版本 (zashboard-settings-pc.json)
PC_URL_TARGET="/ui/zashboard-settings-pc.json"
echo "  -> 正在生成 PC 版本 ($OUTPUT_FILE_PC)..."
cp "$OUTPUT_FILE_GENERAL" "$OUTPUT_FILE_PC.tmp" # 从通用版本复制
# 替换导入 URL 为 PC 版自身 (使用 # 分隔符)
sed -i "s#\"config\/import-settings-url\": \".*\",#\"config\/import-settings-url\": \"$PC_URL_TARGET\",#" "$OUTPUT_FILE_PC.tmp"
# 替换 PC 专用配置 (使用 # 分隔符)
sed -i 's#\"config\/use-connecticon-card\": \".*\",#\"config\/use-connecticon-card\": \"false\",#' "$OUTPUT_FILE_PC.tmp"
mv "$OUTPUT_FILE_PC.tmp" "$OUTPUT_FILE_PC"
echo "  ✅ PC 版本生成完毕。"

# =======================================================
# 阶段 6: 覆盖更新备份文件
# =======================================================
echo "6. 正在使用通用版本覆盖更新备份文件..."
cp "$OUTPUT_FILE_GENERAL" "$CONFIG_FILE"
echo "  -> 成功将 $OUTPUT_FILE_GENERAL 覆盖到 $CONFIG_FILE"


# --- 清理和结束 ---
rm -rf "$TEMP_DIR"

echo "--- 任务完成 ---"
echo "✅ 新的配置已保存到 $OUTPUT_FILE_GENERAL, $OUTPUT_FILE_MOBILE, 和 $OUTPUT_FILE_PC"
echo "   原始配置已备份到 $ORIGIN_FILE"