#!/bin/bash

# 定义目录路径
input_dir="/rules/ip"
output_dir="/rules/ip"

# 遍历 rules/ip 目录下的所有 .list 文件
for input_file in "$input_dir"/*.list; do
  # 获取文件名（不含扩展名）
  base_name=$(basename "$input_file" .list)
  
  # 定义输出文件名
  output_file="rules/ip/${base_name}.yaml"
  
  # 写入 YAML 文件的头部
  echo "payload:" > "$output_file"
  
  # 读取并处理 .list 文件中的每一行
  while IFS=, read -r type ip; do
    if [[ -n "$ip" && ! "$ip" =\~ ^# ]]; then
      echo "  - $ip" >> "$output_file"
    fi
  done < "$input_file"
  
  echo "转换完成: $input_file -> $output_file"
done

echo "所有文件转换完成！"
