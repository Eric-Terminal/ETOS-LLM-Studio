#!/usr/bin/env python3
"""
ETOS LLM Studio - 电脑端调试服务器
通过 WebSocket 接收来自 watchOS/iOS 设备的反向连接
提供交互式菜单操作文件系统和捕获 OpenAI 请求
"""

import asyncio
import json
import base64
import os
import socket
from datetime import datetime
from pathlib import Path
import websockets
from websockets.server import serve
from aiohttp import web

def get_local_ip():
    """获取本机局域网IP地址"""
    try:
        # 创建一个UDP socket，不需要真正发送数据
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()
        return local_ip
    except Exception:
        return "无法获取IP"

class DebugServer:
    def __init__(self, host='0.0.0.0', ws_port=8765, http_port=8080):
        self.host = host
        self.ws_port = ws_port
        self.http_port = http_port
        self.device_connection = None
        self.device_name = "未知设备"
        
    async def handle_websocket(self, websocket):
        """处理来自设备的 WebSocket 连接"""
        self.device_connection = websocket
        client_ip = websocket.remote_address[0]
        print(f"\n✅ 设备已连接: {client_ip}")
        self.device_name = f"设备 {client_ip}"
        
        try:
            # 发送 ping 测试连接
            print("[DEBUG] 发送 ping 测试...")
            await self.send_command({"command": "ping"})
            
            # 保持连接，接收响应
            async for message in websocket:
                print(f"[DEBUG] 收到原始消息: {message[:200]}...") if len(message) > 200 else print(f"[DEBUG] 收到消息: {message}")
                try:
                    data = json.loads(message)
                    print(f"[DEBUG] 解析JSON: {data.keys()}")
                    self.handle_response(data)
                except json.JSONDecodeError as e:
                    print(f"[ERROR] JSON解析失败: {e}")
                
        except websockets.exceptions.ConnectionClosed as e:
            print(f"\n🔌 设备断开连接: {client_ip} - {e}")
        except Exception as e:
            print(f"[ERROR] WebSocket错误: {e}")
        finally:
            self.device_connection = None
            print("[DEBUG] 连接已清理")
            
    def handle_response(self, data):
        """处理设备返回的响应"""
        status = data.get('status')
        print(f"[DEBUG] 响应状态: {status}")
        
        if status == 'ok':
            message = data.get('message', '')
            if message:
                print(f"\n✅ 成功: {message}")
            if 'items' in data:
                print(f"[DEBUG] 找到 {len(data['items'])} 个项目")
                self.print_directory_list(data['items'])
            elif 'files' in data:
                # 批量下载
                self.save_all_files(data['files'])
            elif 'data' in data:
                # 单文件下载
                self.save_downloaded_file(data)
        else:
            print(f"\n❌ 错误: {data.get('message', '未知错误')}")
            
    def print_directory_list(self, items):
        """打印目录列表"""
        print("\n📁 目录内容:")
        print(f"{'名称':<40} {'类型':<10} {'大小':<15} {'修改时间':<20}")
        print("-" * 90)
        for item in items:
            name = item['name']
            type_ = '目录' if item['isDirectory'] else '文件'
            size = self.format_size(item['size']) if not item['isDirectory'] else '-'
            mtime = datetime.fromtimestamp(item['modificationDate']).strftime('%Y-%m-%d %H:%M:%S')
            print(f"{name:<40} {type_:<10} {size:<15} {mtime:<20}")
        print()
        
    def format_size(self, bytes_):
        """格式化文件大小"""
        for unit in ['B', 'KB', 'MB', 'GB']:
            if bytes_ < 1024:
                return f"{bytes_:.1f} {unit}"
            bytes_ /= 1024
        return f"{bytes_:.1f} TB"
        
    def save_downloaded_file(self, data):
        """保存下载的文件"""
        path = data.get('path', 'download')
        b64_data = data.get('data', '')
        
        try:
            file_data = base64.b64decode(b64_data)
            filename = Path(path).name
            local_path = Path('downloads') / filename
            local_path.parent.mkdir(exist_ok=True)
            
            with open(local_path, 'wb') as f:
                f.write(file_data)
            print(f"\n💾 文件已保存: {local_path} ({self.format_size(len(file_data))})")
        except Exception as e:
            print(f"\n❌ 保存文件失败: {e}")
    
    def save_all_files(self, files):
        """批量保存文件"""
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        backup_dir = Path('downloads') / f'Documents_backup_{timestamp}'
        backup_dir.mkdir(parents=True, exist_ok=True)
        
        print(f"\n📦 开始保存 {len(files)} 个文件到: {backup_dir}")
        
        for file_info in files:
            try:
                path = file_info['path']
                b64_data = file_info['data']
                file_data = base64.b64decode(b64_data)
                
                local_path = backup_dir / path
                local_path.parent.mkdir(parents=True, exist_ok=True)
                
                with open(local_path, 'wb') as f:
                    f.write(file_data)
                print(f"  ✅ {path} ({self.format_size(len(file_data))})")
            except Exception as e:
                print(f"  ❌ {path}: {e}")
        
        print(f"\n💾 全部保存完成: {backup_dir}")
            
    async def send_command(self, command):
        """发送命令到设备"""
        if not self.device_connection:
            print("[ERROR] 设备未连接")
            return False
            
        try:
            cmd_str = json.dumps(command)
            print(f"[DEBUG] 发送命令: {cmd_str}")
            await self.device_connection.send(cmd_str)
            return True
        except Exception as e:
            print(f"[ERROR] 发送命令失败: {e}")
            return False
            
    async def interactive_menu(self):
        """交互式菜单"""
        while True:
            await asyncio.sleep(0.1)  # 给 WebSocket 处理留空间
            
            if not self.device_connection:
                print("\n⏳ 等待设备连接...")
                await asyncio.sleep(5)
                continue
                
            print(f"\n{'='*60}")
            print(f"📱 {self.device_name} - ETOS LLM Studio 调试控制台")
            print(f"{'='*60}")
            print("1. 📂 列出设备目录")
            print("2. 📥 下载文件（设备→电脑）")
            print("3. 📤 上传文件（电脑→设备）")
            print("4. 🗑️  删除设备文件/目录")
            print("5. 📁 在设备创建目录")
            print("6. 📦 一键下载 Documents 目录")
            print("7. 🚀 一键上传覆盖 Documents")
            print("8. 🔄 刷新连接")
            print("0. 🚺 退出")
            print(f"{'='*60}")
            
            try:
                choice = await asyncio.to_thread(input, "请选择操作 [0-8]: ")
            except EOFError:
                await asyncio.sleep(1)
                continue
                
            if choice == '1':
                path = await asyncio.to_thread(input, "设备路径 (留空或输入 . 为 Documents): ") or "."
                await self.send_command({"command": "list", "path": path})
                await asyncio.sleep(1)  # 等待响应
                
            elif choice == '2':
                path = await asyncio.to_thread(input, "设备文件路径: ")
                if path:
                    await self.send_command({"command": "download", "path": path})
                    await asyncio.sleep(1)  # 等待下载完成
                    
            elif choice == '3':
                local_file = await asyncio.to_thread(input, "本地文件路径: ")
                remote_path = await asyncio.to_thread(input, "设备目标路径: ")
                if os.path.exists(local_file) and remote_path:
                    with open(local_file, 'rb') as f:
                        data = base64.b64encode(f.read()).decode()
                    await self.send_command({
                        "command": "upload",
                        "path": remote_path,
                        "data": data
                    })
                    await asyncio.sleep(1)
                else:
                    print("❌ 文件不存在或路径为空")
                    
            elif choice == '4':
                path = await asyncio.to_thread(input, "要删除的设备路径: ")
                if path:
                    confirm = await asyncio.to_thread(input, f"确认删除设备上的 '{path}'? (yes/no): ")
                    if confirm.lower() == 'yes':
                        await self.send_command({"command": "delete", "path": path})
                        await asyncio.sleep(1)
                        
            elif choice == '5':
                path = await asyncio.to_thread(input, "在设备创建目录: ")
                if path:
                    await self.send_command({"command": "mkdir", "path": path})
                    await asyncio.sleep(1)
            
            elif choice == '6':
                print("📦 准备下载整个 Documents 目录...")
                await self.send_command({"command": "download_all"})
                print("⏳ 等待设备打包和传输...")
                await asyncio.sleep(5)  # 等待打包和下载
            
            elif choice == '7':
                local_dir = await asyncio.to_thread(input, "本地目录路径 (将覆盖设备 Documents): ")
                if os.path.isdir(local_dir):
                    confirm = await asyncio.to_thread(input, f"⚠️  确认覆盖设备 Documents 目录? 所有数据将被删除! (yes/no): ")
                    if confirm.lower() == 'yes':
                        print("📦 扫描本地目录...")
                        
                        files = []
                        for root, dirs, filenames in os.walk(local_dir):
                            for filename in filenames:
                                file_path = os.path.join(root, filename)
                                rel_path = os.path.relpath(file_path, local_dir)
                                
                                with open(file_path, 'rb') as f:
                                    data = base64.b64encode(f.read()).decode()
                                
                                files.append({
                                    "path": rel_path,
                                    "data": data
                                })
                                print(f"  ➤ {rel_path}")
                        
                        print(f"\n📤 上传 {len(files)} 个文件到设备...")
                        print("⏳ 设备将清空 Documents 并写入文件...")
                        
                        await self.send_command({
                            "command": "upload_all",
                            "files": files
                        })
                        await asyncio.sleep(5)
                else:
                    print("❌ 目录不存在")
                    
            elif choice == '8':
                if self.device_connection:
                    await self.send_command({"command": "ping"})
                    await asyncio.sleep(0.5)
                    print("✅ 已发送 ping")
                    
            elif choice == '0':
                print("👋 再见!")
                break
                
    async def handle_http_request(self, request):
        """处理 HTTP OpenAI 代理请求"""
        if request.path == '/v1/chat/completions' and request.method == 'POST':
            try:
                openai_data = await request.json()
                
                # 转发到设备
                if self.device_connection:
                    await self.send_command({
                        "command": "openai_capture",
                        "request": openai_data
                    })
                    print(f"\n📨 OpenAI 请求已转发到设备")
                    
                # 返回空响应（让实际 API 处理）
                return web.json_response({
                    "id": "proxy-capture",
                    "object": "chat.completion",
                    "created": int(datetime.now().timestamp()),
                    "model": openai_data.get("model", "unknown"),
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": ""},
                        "finish_reason": "stop"
                    }]
                })
            except Exception as e:
                print(f"❌ 处理 OpenAI 请求失败: {e}")
                return web.json_response({"error": str(e)}, status=500)
        
        return web.Response(text="ETOS LLM Studio Proxy", status=200)
        
    async def start_http_proxy(self):
        """启动 HTTP 代理服务器（用于捕获 OpenAI 请求）"""
        app = web.Application()
        app.router.add_post('/v1/chat/completions', self.handle_http_request)
        app.router.add_get('/', self.handle_http_request)
        
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, self.host, self.http_port)
        await site.start()
        print(f"🌐 HTTP 代理服务器已启动: http://{self.host}:{self.http_port}")
        
    async def run(self):
        """启动服务器"""
        local_ip = get_local_ip()
        
        print(f"""
╔══════════════════════════════════════════════════════════════╗
║  ETOS LLM Studio - 反向探针调试服务器                       ║
╚══════════════════════════════════════════════════════════════╝

🖥️  本机局域网IP: {local_ip}
📡 WebSocket 服务器: ws://{local_ip}:{self.ws_port}
🌐 HTTP 代理服务器: http://{local_ip}:{self.http_port}

💡 使用说明:
  1. 在设备上输入: {local_ip}
  2. 默认 WebSocket 端口: {self.ws_port}
  3. 设备连接后会自动进入操作菜单
  4. OpenAI API 设置为: http://{local_ip}:{self.http_port}

⏳ 等待设备连接...
        """)
        
        # 启动 WebSocket 服务器
        async with serve(self.handle_websocket, self.host, self.ws_port):
            # 启动 HTTP 代理
            await self.start_http_proxy()
            
            # 启动交互菜单
            await self.interactive_menu()

def main():
    import sys
    
    host = '0.0.0.0'
    ws_port = 8765
    http_port = 8080
    
    if len(sys.argv) > 1:
        ws_port = int(sys.argv[1])
    if len(sys.argv) > 2:
        http_port = int(sys.argv[2])
        
    server = DebugServer(host, ws_port, http_port)
    
    try:
        asyncio.run(server.run())
    except KeyboardInterrupt:
        print("\n\n👋 服务器已停止")

if __name__ == '__main__':
    main()
