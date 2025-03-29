#!/bin/bash

# 定义目录路径
input_dir="/rules/domain"
output_dir="/rules/domain"

# 遍历 /rules/domain 目录下的所有 .list 文件
for input_file in "$input_dir"/*.list; do
    # 获取文件名（不带扩展名）
    base_name=$(basename "$input_file" .list)
    
    # 定义输出文件路径
    output_file="$output_dir/$base_name.yaml"
    
    # 初始化 YAML 文件
    echo "payload:" > "$output_file"
    
    # 读取 .list 文件并处理每一行
    while IFS=, read -r type domain; do
        if [[ -n "$domain" && ! "$domain" =\~ ^# ]]; then
            # 如果是 DOMAIN-SUFFIX 规则，前面加上 *.
            if [[ "$type" == "DOMAIN-SUFFIX" ]]; then
                domain="*.$domain"
            fi
            # 写入到 YAML 文件
            echo "  - $domain" >> "$output_file"
        fi
    done < "$input_file"
    
    echo "Processed $input_file -> $output_file"
done

echo "All files processed."
