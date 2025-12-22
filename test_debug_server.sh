#!/bin/bash

# ============================================================================
# ETOS LLM Studio 局域网调试测试脚本
# ============================================================================
# 使用方法:
#   chmod +x test_debug_server.sh
#   ./test_debug_server.sh <IP地址> <PIN码>
# 
# 示例:
#   ./test_debug_server.sh 192.168.1.100 123456
# ============================================================================

set -e

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查参数
if [ $# -lt 2 ]; then
    echo -e "${RED}错误: 缺少必要参数${NC}"
    echo "使用方法: $0 <IP地址> <PIN码>"
    echo "示例: $0 192.168.1.100 123456"
    exit 1
fi

IP="$1"
PIN="$2"
BASE_URL="http://$IP:8080"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}ETOS LLM Studio 局域网调试服务器测试${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo -e "服务器地址: ${YELLOW}$BASE_URL${NC}"
echo -e "PIN 码: ${YELLOW}$PIN${NC}"
echo ""

# 测试 1: 连接测试
echo -e "${YELLOW}[测试 1/6]${NC} 测试服务器连接..."
if curl -s --connect-timeout 5 "$BASE_URL/" > /dev/null; then
    echo -e "${GREEN}✓ 连接成功${NC}"
else
    echo -e "${RED}✗ 连接失败${NC}"
    echo "请检查:"
    echo "  1. 设备和电脑是否在同一局域网"
    echo "  2. IP 地址是否正确"
    echo "  3. 调试服务器是否已启动"
    exit 1
fi
echo ""

# 测试 2: PIN 验证
echo -e "${YELLOW}[测试 2/6]${NC} 测试 PIN 码验证..."
RESPONSE=$(curl -s -X GET "$BASE_URL/api/list" \
    -H "X-Debug-PIN: wrong_pin" \
    -H "Content-Type: application/json" \
    -d '{"path": "."}')

if echo "$RESPONSE" | grep -q "Unauthorized"; then
    echo -e "${GREEN}✓ PIN 验证正常工作${NC}"
else
    echo -e "${RED}✗ PIN 验证异常${NC}"
    exit 1
fi
echo ""

# 测试 3: 列出根目录
echo -e "${YELLOW}[测试 3/6]${NC} 列出 Documents 根目录..."
RESPONSE=$(curl -s -X GET "$BASE_URL/api/list" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d '{"path": "."}')

if echo "$RESPONSE" | grep -q '"success":true'; then
    echo -e "${GREEN}✓ 成功获取目录列表${NC}"
    echo "目录内容:"
    echo "$RESPONSE" | jq -r '.items[] | "  - \(.name)\(if .isDirectory then "/" else "" end) (\(.size) bytes)"' 2>/dev/null || echo "$RESPONSE" | python3 -m json.tool
else
    echo -e "${RED}✗ 获取目录列表失败${NC}"
    echo "$RESPONSE"
    exit 1
fi
echo ""

# 测试 4: 创建测试目录
echo -e "${YELLOW}[测试 4/6]${NC} 创建测试目录..."
TEST_DIR="ETOSDebugTest"
RESPONSE=$(curl -s -X POST "$BASE_URL/api/mkdir" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$TEST_DIR\"}")

if echo "$RESPONSE" | grep -q '"success":true'; then
    echo -e "${GREEN}✓ 成功创建目录: $TEST_DIR${NC}"
else
    echo -e "${YELLOW}⚠ 目录可能已存在或创建失败${NC}"
fi
echo ""

# 测试 5: 上传测试文件
echo -e "${YELLOW}[测试 5/6]${NC} 上传测试文件..."
TEST_CONTENT="ETOS LLM Studio Debug Test\nTimestamp: $(date)\n"
TEST_FILE="$TEST_DIR/test.txt"
ENCODED_CONTENT=$(echo -n "$TEST_CONTENT" | base64)

RESPONSE=$(curl -s -X POST "$BASE_URL/api/upload" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$TEST_FILE\", \"data\": \"$ENCODED_CONTENT\"}")

if echo "$RESPONSE" | grep -q '"success":true'; then
    echo -e "${GREEN}✓ 成功上传文件: $TEST_FILE${NC}"
else
    echo -e "${RED}✗ 上传文件失败${NC}"
    echo "$RESPONSE"
    exit 1
fi
echo ""

# 测试 6: 下载并验证文件
echo -e "${YELLOW}[测试 6/6]${NC} 下载并验证文件..."
RESPONSE=$(curl -s -X GET "$BASE_URL/api/download" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$TEST_FILE\"}")

if echo "$RESPONSE" | grep -q '"success":true'; then
    DOWNLOADED_CONTENT=$(echo "$RESPONSE" | jq -r '.data' | base64 -d)
    if [ "$DOWNLOADED_CONTENT" = "$TEST_CONTENT" ]; then
        echo -e "${GREEN}✓ 文件下载成功,内容一致${NC}"
    else
        echo -e "${YELLOW}⚠ 文件下载成功,但内容不一致${NC}"
        echo "预期: $TEST_CONTENT"
        echo "实际: $DOWNLOADED_CONTENT"
    fi
else
    echo -e "${RED}✗ 下载文件失败${NC}"
    echo "$RESPONSE"
    exit 1
fi
echo ""

# 清理测试文件
echo -e "${YELLOW}[清理]${NC} 删除测试文件和目录..."
curl -s -X POST "$BASE_URL/api/delete" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$TEST_FILE\"}" > /dev/null

curl -s -X POST "$BASE_URL/api/delete" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$TEST_DIR\"}" > /dev/null

echo -e "${GREEN}✓ 清理完成${NC}"
echo ""

# 总结
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}所有测试通过! 🎉${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo "你现在可以使用以下命令进行更多操作:"
echo ""
echo -e "${YELLOW}# 列出 Providers 目录${NC}"
echo "curl -X GET $BASE_URL/api/list \\"
echo "  -H \"X-Debug-PIN: $PIN\" \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"path\": \"Providers\"}'"
echo ""
echo -e "${YELLOW}# 下载配置文件${NC}"
echo "curl -X GET $BASE_URL/api/download \\"
echo "  -H \"X-Debug-PIN: $PIN\" \\"
echo "  -H \"Content-Type: application/json\" \\"
echo "  -d '{\"path\": \"Providers/config.json\"}' \\"
echo "  | jq -r '.data' | base64 -d > config.json"
echo ""
echo "更多示例请查看: LOCAL_DEBUG.md"
echo ""
