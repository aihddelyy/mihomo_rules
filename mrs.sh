#!/bin/bash
cd rules/yaml
find . -name "*.yaml" | while read -r file; do    
    filename=$(basename "$file" .yaml)

    if [[ "$filename" == *ip* ]]; then
        param="ipcidr"
    else
        param="domain"
    fi

    output_file="$filename.mrs"

    /usr/local/bin/mihomo convert-ruleset "$param" yaml "$file" "$output_file"

    if [[ $? -eq 0 ]]; then
        echo "文件 $file 转换成功为 $output_file"
    else
        echo "文件 $file 转换失败"
    fi
done
mv *.mrs ../mrs/