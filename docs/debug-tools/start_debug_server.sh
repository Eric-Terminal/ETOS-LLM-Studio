#!/bin/bash
# ETOS LLM Studio 调试服务器快速启动脚本

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ETOS LLM Studio - 反向探针调试服务器                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# 检查 Python 依赖
if ! python3 -c "import websockets" 2>/dev/null; then
    echo "⚠️  未找到 websockets 库，正在安装..."
    pip3 install -r requirements.txt
fi

# 获取本机 IP
echo "🔍 检测本机 IP 地址..."
if command -v ipconfig &> /dev/null; then
    # macOS
    LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "未知")
else
    # Linux
    LOCAL_IP=$(hostname -I | awk '{print $1}')
fi

echo ""
echo "📡 本机 IP 地址: $LOCAL_IP"
echo "💡 请在设备上输入此 IP 地址"
echo ""

# 启动服务器
python3 debug_server.py
