#!/bin/bash

# 默认参数
LISTEN_PORT=8888
TARGET_PORT=80
MODE="http"   # 或 "stream" (TCP 转发)

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--listen-port)
            LISTEN_PORT="$2"
            shift 2
            ;;
        -t|--target-port)
            TARGET_PORT="$2"
            shift 2
            ;;
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: $0 [-l 监听端口] [-t 目标端口] [-m http|stream]"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# 检查是否以 root 运行
if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

# 检查 nginx 是否存在
if ! command -v nginx &> /dev/null; then
    echo "未找到 nginx 命令，请先安装 nginx"
    exit 1
fi

# 生成配置内容
if [[ "$MODE" == "http" ]]; then
    # HTTP 反向代理配置
    CONF_CONTENT=$(cat <<EOF
server {
    listen ${LISTEN_PORT};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${TARGET_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
)
    CONF_FILE="/etc/nginx/conf.d/port-forward-${LISTEN_PORT}.conf"
elif [[ "$MODE" == "stream" ]]; then
    # TCP/UDP 转发配置（需要 stream 模块）
    CONF_CONTENT=$(cat <<EOF
stream {
    server {
        listen ${LISTEN_PORT};
        proxy_pass 127.0.0.1:${TARGET_PORT};
    }
}
EOF
)
    CONF_FILE="/etc/nginx/conf.d/port-forward-${LISTEN_PORT}.stream.conf"
else
    echo "模式只能是 http 或 stream"
    exit 1
fi

# 检查 /etc/nginx/conf.d/ 是否存在，如果不存在则尝试直接修改 nginx.conf
if [[ -d "/etc/nginx/conf.d" ]]; then
    # 写入独立配置文件
    echo "写入配置到 ${CONF_FILE}"
    echo "$CONF_CONTENT" > "$CONF_FILE"
else
    echo "未找到 /etc/nginx/conf.d/ 目录，尝试将配置插入 /etc/nginx/nginx.conf"
    NGINX_CONF="/etc/nginx/nginx.conf"
    if [[ ! -f "$NGINX_CONF" ]]; then
        echo "找不到 nginx 主配置文件：$NGINX_CONF"
        exit 1
    fi

    if [[ "$MODE" == "http" ]]; then
        # 检查 http 块中是否已有相同监听端口的 server
        if grep -q "listen ${LISTEN_PORT};" "$NGINX_CONF"; then
            echo "nginx.conf 中已存在监听 ${LISTEN_PORT} 的配置，请手动检查"
            exit 1
        fi
        # 将 server 块插入到 http 块内（简单方式：在最后一个 } 前插入）
        # 更安全的做法是使用 sed 在 http { ... } 内插入，但这里采用追加方式不够准确
        # 实际生产建议使用 conf.d 目录，此处仅为应急
        echo "警告：自动修改 nginx.conf 可能有风险，建议手动添加以下配置到 http 块内："
        echo "$CONF_CONTENT"
        exit 1
    else
        # stream 配置一般独立在 stream 块中，如果不存在 stream 块则无法自动添加
        if ! grep -q "stream {" "$NGINX_CONF"; then
            echo "nginx.conf 中没有 stream 块，请手动添加 stream 配置"
            exit 1
        fi
        # 同样建议手动处理
        echo "建议手动将以下内容添加到 stream 块内："
        echo "$CONF_CONTENT"
        exit 1
    fi
fi

# 测试 nginx 配置
echo "测试 nginx 配置..."
nginx -t
if [[ $? -ne 0 ]]; then
    echo "nginx 配置测试失败，请检查上述输出"
    # 删除刚才写入的文件，避免错误配置残留
    rm -f "$CONF_FILE"
    exit 1
fi

# 重载 nginx
echo "重载 nginx..."
nginx -s reload
if [[ $? -eq 0 ]]; then
    echo "成功！现在访问端口 ${LISTEN_PORT} 将转发到本机 ${TARGET_PORT}"
else
    echo "nginx 重载失败，请检查错误信息"
    exit 1
fi