# 局域网调试功能文档

## 概述

ETOS LLM Studio 提供局域网调试功能,允许开发者通过命令行工具在局域网内远程访问和管理应用的 Documents 目录。这对于需要频繁编辑配置文件(如 Providers、MCP、Memory、ChatSession 等)的场景非常有用。

## 安全特性

- **PIN 码认证**: 每次启动服务器都会生成一个随机的 6 位 PIN 码
- **路径限制**: 所有操作仅限于应用沙盒的 Documents 目录内
- **自动停止**: 退出调试界面时服务器自动停止
- **屏幕常亮**: 服务器运行期间保持屏幕常亮,防止意外中断

## 使用方法

### 1. 启动服务器

在 iOS 或 watchOS 设备上:
1. 打开 ETOS LLM Studio
2. 进入 **设置** → **拓展功能** → **局域网调试**
3. 点击 **启动调试服务器**
4. 记录显示的 **IP 地址** 和 **PIN 码**

### 2. 验证连接

在局域网内的电脑上,使用浏览器访问:

```
http://<设备IP>:8080
```

如果能看到欢迎页面,说明连接成功。

## API 端点

所有 API 请求都需要在 HTTP Header 中包含 PIN 码:

```
X-Debug-PIN: <6位PIN码>
```

### 1. 列出目录内容

**端点**: `GET /api/list`

**请求体**:
```json
{
  "path": "Providers"
}
```

**示例**:
```bash
curl -X GET http://192.168.1.100:8080/api/list \
  -H "X-Debug-PIN: 123456" \
  -H "Content-Type: application/json" \
  -d '{"path": "Providers"}'
```

**响应**:
```json
{
  "success": true,
  "path": "Providers",
  "items": [
    {
      "name": "config.json",
      "isDirectory": false,
      "size": 1024,
      "modificationDate": 1703232000.0
    },
    {
      "name": "SubFolder",
      "isDirectory": true,
      "size": 0,
      "modificationDate": 1703232000.0
    }
  ]
}
```

### 2. 下载文件

**端点**: `GET /api/download`

**请求体**:
```json
{
  "path": "Providers/config.json"
}
```

**示例**:
```bash
# 下载并保存文件
curl -X GET http://192.168.1.100:8080/api/download \
  -H "X-Debug-PIN: 123456" \
  -H "Content-Type: application/json" \
  -d '{"path": "Providers/config.json"}' \
  | jq -r '.data' | base64 -d > config.json
```

**响应**:
```json
{
  "success": true,
  "path": "Providers/config.json",
  "data": "base64编码的文件内容",
  "size": 1024
}
```

### 3. 上传文件

**端点**: `POST /api/upload`

**请求体**:
```json
{
  "path": "Providers/new_config.json",
  "data": "base64编码的文件内容"
}
```

**示例**:
```bash
# 上传本地文件
curl -X POST http://192.168.1.100:8080/api/upload \
  -H "X-Debug-PIN: 123456" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"Providers/new_config.json\", \"data\": \"$(base64 < config.json)\"}"
```

**响应**:
```json
{
  "success": true,
  "path": "Providers/new_config.json",
  "size": 1024
}
```

### 4. 删除文件或目录

**端点**: `POST /api/delete`

**请求体**:
```json
{
  "path": "Providers/old_config.json"
}
```

**示例**:
```bash
curl -X POST http://192.168.1.100:8080/api/delete \
  -H "X-Debug-PIN: 123456" \
  -H "Content-Type: application/json" \
  -d '{"path": "Providers/old_config.json"}'
```

**响应**:
```json
{
  "success": true,
  "path": "Providers/old_config.json"
}
```

### 5. 创建目录

**端点**: `POST /api/mkdir`

**请求体**:
```json
{
  "path": "NewFolder/SubFolder"
}
```

**示例**:
```bash
# 支持递归创建多级目录
curl -X POST http://192.168.1.100:8080/api/mkdir \
  -H "X-Debug-PIN: 123456" \
  -H "Content-Type: application/json" \
  -d '{"path": "NewFolder/SubFolder"}'
```

**响应**:
```json
{
  "success": true,
  "path": "NewFolder/SubFolder"
}
```

## 错误响应格式

所有错误响应都遵循以下格式:

```json
{
  "success": false,
  "error": "错误描述信息"
}
```

常见错误码:
- **400 Bad Request**: 请求参数错误
- **401 Unauthorized**: PIN 码错误或未提供
- **403 Forbidden**: 尝试访问 Documents 目录外的路径
- **404 Not Found**: 文件或目录不存在
- **500 Internal Server Error**: 服务器内部错误

## 实用脚本示例

### 备份整个 Documents 目录

```bash
#!/bin/bash

IP="192.168.1.100"
PIN="123456"
BACKUP_DIR="./etos_backup"

mkdir -p "$BACKUP_DIR"

# 递归下载函数
download_dir() {
    local path="$1"
    local local_path="$BACKUP_DIR/$path"
    
    mkdir -p "$local_path"
    
    # 获取目录列表
    items=$(curl -s -X GET "http://$IP:8080/api/list" \
        -H "X-Debug-PIN: $PIN" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$path\"}" \
        | jq -r '.items[]')
    
    echo "$items" | jq -c '.' | while read item; do
        name=$(echo "$item" | jq -r '.name')
        is_dir=$(echo "$item" | jq -r '.isDirectory')
        
        if [ "$is_dir" = "true" ]; then
            download_dir "$path/$name"
        else
            echo "下载: $path/$name"
            curl -s -X GET "http://$IP:8080/api/download" \
                -H "X-Debug-PIN: $PIN" \
                -H "Content-Type: application/json" \
                -d "{\"path\": \"$path/$name\"}" \
                | jq -r '.data' | base64 -d > "$local_path/$name"
        fi
    done
}

# 从根目录开始备份
download_dir "."
echo "备份完成!"
```

### 批量上传文件

```bash
#!/bin/bash

IP="192.168.1.100"
PIN="123456"
LOCAL_DIR="./configs"
REMOTE_DIR="Providers"

# 上传目录中的所有文件
for file in "$LOCAL_DIR"/*; do
    filename=$(basename "$file")
    echo "上传: $filename"
    
    curl -X POST "http://$IP:8080/api/upload" \
        -H "X-Debug-PIN: $PIN" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$REMOTE_DIR/$filename\", \"data\": \"$(base64 < "$file")\"}"
done

echo "上传完成!"
```

### 快速编辑配置文件

```bash
#!/bin/bash

IP="192.168.1.100"
PIN="123456"
FILE_PATH="Providers/config.json"

# 下载文件
echo "下载配置文件..."
curl -s -X GET "http://$IP:8080/api/download" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$FILE_PATH\"}" \
    | jq -r '.data' | base64 -d > /tmp/config.json

# 用编辑器打开
${EDITOR:-nano} /tmp/config.json

# 上传修改后的文件
echo "上传修改后的配置..."
curl -X POST "http://$IP:8080/api/upload" \
    -H "X-Debug-PIN: $PIN" \
    -H "Content-Type: application/json" \
    -d "{\"path\": \"$FILE_PATH\", \"data\": \"$(base64 < /tmp/config.json)\"}"

echo "完成!"
```

## Python 客户端示例

```python
import requests
import base64
import json

class ETOSDebugClient:
    def __init__(self, ip, pin, port=8080):
        self.base_url = f"http://{ip}:{port}"
        self.pin = pin
        self.headers = {
            "X-Debug-PIN": pin,
            "Content-Type": "application/json"
        }
    
    def list_dir(self, path):
        """列出目录内容"""
        response = requests.get(
            f"{self.base_url}/api/list",
            headers=self.headers,
            json={"path": path}
        )
        return response.json()
    
    def download_file(self, path, local_path):
        """下载文件"""
        response = requests.get(
            f"{self.base_url}/api/download",
            headers=self.headers,
            json={"path": path}
        )
        data = response.json()
        if data["success"]:
            content = base64.b64decode(data["data"])
            with open(local_path, "wb") as f:
                f.write(content)
            return True
        return False
    
    def upload_file(self, local_path, remote_path):
        """上传文件"""
        with open(local_path, "rb") as f:
            content = base64.b64encode(f.read()).decode()
        
        response = requests.post(
            f"{self.base_url}/api/upload",
            headers=self.headers,
            json={"path": remote_path, "data": content}
        )
        return response.json()
    
    def delete(self, path):
        """删除文件或目录"""
        response = requests.post(
            f"{self.base_url}/api/delete",
            headers=self.headers,
            json={"path": path}
        )
        return response.json()
    
    def mkdir(self, path):
        """创建目录"""
        response = requests.post(
            f"{self.base_url}/api/mkdir",
            headers=self.headers,
            json={"path": path}
        )
        return response.json()

# 使用示例
if __name__ == "__main__":
    client = ETOSDebugClient("192.168.1.100", "123456")
    
    # 列出 Providers 目录
    result = client.list_dir("Providers")
    print(json.dumps(result, indent=2))
    
    # 下载配置文件
    client.download_file("Providers/config.json", "./config.json")
    
    # 上传修改后的文件
    client.upload_file("./config.json", "Providers/config.json")
```

## 常见问题

### Q: 无法连接到服务器?

A: 检查以下几点:
1. 确保设备和电脑在同一局域网内
2. 确认 IP 地址正确
3. 检查防火墙设置是否阻止了端口 8080
4. 确保服务器仍在运行(屏幕未锁定)

### Q: 收到 401 Unauthorized 错误?

A: 检查 PIN 码是否正确。PIN 码每次启动服务器都会重新生成。

### Q: 上传大文件失败?

A: 当前实现限制单次请求大小为 64KB。对于大文件,考虑分块上传或使用其他传输方式。

### Q: 如何在 watchOS 上使用?

A: watchOS 版本功能与 iOS 版本相同,只是界面适配了手表尺寸。建议在手表上启动服务器后,在电脑上进行操作。

## 安全建议

1. **仅在可信任的局域网中使用**: 不要在公共 Wi-Fi 或不安全的网络中启用此功能
2. **及时停止服务器**: 使用完毕后立即停止服务器
3. **不要分享 PIN 码**: PIN 码相当于临时密码,不要通过不安全的渠道传输
4. **定期备份**: 在进行大规模修改前,先备份重要数据
5. **谨慎操作**: 删除操作不可恢复,请确认后再执行

## 技术细节

- **协议**: HTTP/1.1
- **端口**: 8080 (固定)
- **传输编码**: Base64
- **JSON 格式**: UTF-8
- **最大请求大小**: 64KB
- **并发连接**: 支持多个并发连接

## 更新日志

### v1.0.0 (2025-12-22)
- 初始发布
- 支持基本的文件操作(列表、下载、上传、删除、创建目录)
- PIN 码认证
- iOS 和 watchOS 支持
- 屏幕常亮功能

## 许可

本功能遵循 ETOS LLM Studio 的整体许可协议。
