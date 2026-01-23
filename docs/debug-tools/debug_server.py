#!/usr/bin/env python3
"""
ETOS LLM Studio - 电脑端调试服务器
通过 WebSocket 或 HTTP 轮询接收来自 watchOS/iOS 设备的连接
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

# ============================================================================
# 调试配置 - 用户可修改
# ============================================================================
DEBUG_MODE = False  # 设置为 True 查看详细请求体，False 只显示摘要
# ============================================================================

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
    def __init__(self, host='0.0.0.0', ws_port=8765, http_port=7654, proxy_port=8080):
        self.host = host
        self.ws_port = ws_port
        self.http_port = http_port
        self.proxy_port = proxy_port
        self.device_connection = None
        self.device_name = "未知设备"
        self.last_poll_time = None  # 最后轮询时间（HTTP模式）
        
        # HTTP 轮询相关
        self.command_queue = []  # 待发送的命令队列
        self.response_queue = []  # 收到的响应队列
        self.http_app = None
        
        # 流式传输相关
        self.stream_backup_dir = None  # 流式接收的保存目录
        self.upload_file_queue = []  # 流式上传的文件队列（电脑→设备）
        self.upload_in_progress = False  # 是否正在进行流式上传
        self.download_in_progress = False  # 是否正在进行流式下载
        self.download_file_count = 0  # 下载文件计数
        self.download_expected_total = 0  # 期望下载总数
        
        # 兼容模式下载相关
        self.compatible_download_in_progress = False  # 兼容模式下载进行中
        self.compatible_file_list = None  # 待下载的文件路径列表
        self.compatible_download_event = None  # 用于等待响应的事件
        
    async def handle_websocket(self, websocket):
        """处理来自设备的 WebSocket 连接"""
        self.device_connection = websocket
        client_ip = websocket.remote_address[0]
        print(f"\n✅ 设备已连接 (WebSocket): {client_ip}")
        self.device_name = f"设备 {client_ip}"
        
        try:
            # 发送 ping 测试连接
            if DEBUG_MODE:
                print("[DEBUG] 发送 ping 测试...")
            await self.send_command({"command": "ping"})
            
            # 保持连接，接收响应
            async for message in websocket:
                if DEBUG_MODE:
                    if len(message) > 200:
                        print(f"[DEBUG] 收到原始消息: {message[:200]}...")
                    else:
                        print(f"[DEBUG] 收到消息: {message}")
                
                try:
                    data = json.loads(message)
                    if DEBUG_MODE:
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
            if DEBUG_MODE:
                print("[DEBUG] 连接已清理")
            
    def handle_response(self, data):
        """处理设备返回的响应（WebSocket 和 HTTP 共用）"""
        status = data.get('status')
        
        if DEBUG_MODE:
            print(f"[DEBUG] 响应状态: {status}, 键: {list(data.keys())}")
        
        if status == 'ok':
            message = data.get('message', '')
            
            # 流式下载完成标志
            if data.get('stream_complete'):
                total = data.get('total', 0)
                success_count = data.get('success_count', total)  # 实际成功发送的文件数
                fail_count = data.get('fail_count', 0)
                
                # 保存目录路径（在重置前）
                saved_dir = self.stream_backup_dir
                received_count = self.download_file_count
                
                self.download_in_progress = False  # 下载完成
                
                print(f"\n\n✅ 流式下载完成！")
                print(f"   📊 设备报告: 总计 {total}, 成功发送 {success_count}, 失败 {fail_count}")
                print(f"   📥 服务器收到: {received_count} 个文件")
                
                # 🔥 验证：检查实际收到的文件数是否与设备发送的一致
                if received_count < success_count:
                    print(f"   ⚠️  警告: 有 {success_count - received_count} 个文件可能丢失！")
                    print(f"      (设备发送了 {success_count} 个，但只收到 {received_count} 个)")
                elif received_count == success_count and success_count > 0:
                    print(f"   ✅ 验证通过: 所有文件都已收到")
                
                if saved_dir:
                    print(f"💾 保存目录: {saved_dir}")
                elif total > 0 and received_count == 0:
                    print(f"⚠️  警告: 收到完成信号但未收到任何文件数据！")
                    print(f"      这可能是网络乱序问题，请重试")
                else:
                    print(f"💾 保存目录: 无文件需要保存")
                
                self.stream_backup_dir = None  # 重置
                self.download_file_count = 0  # 重置计数
                self.download_expected_total = 0  # 重置期望总数
                return
            
            # 流式下载：单个文件
            if 'path' in data and 'data' in data and 'index' in data:
                self.download_file_count = data.get('index', 0)
                self.download_expected_total = data.get('total', 0)
                self.save_stream_file(data)
            # 兼容模式：收到文件路径列表（list_all 响应）
            elif 'paths' in data and 'total' in data:
                self.compatible_file_list = data.get('paths', [])
                total = data.get('total', 0)
                print(f"\n📋 收到文件列表: {total} 个文件")
                if self.compatible_download_event:
                    self.compatible_download_event.set()
            # 批量下载：所有文件（WebSocket模式）
            elif 'items' in data:
                if DEBUG_MODE:
                    print(f"[DEBUG] 找到 {len(data['items'])} 个项目")
                self.print_directory_list(data['items'])
            elif 'files' in data:
                self.save_all_files(data['files'])
            # 单文件下载（兼容模式或普通下载）
            elif 'data' in data and 'path' in data:
                if self.compatible_download_in_progress:
                    # 兼容模式：保存到指定目录，然后触发事件
                    self.save_compatible_file(data)
                    if self.compatible_download_event:
                        self.compatible_download_event.set()
                else:
                    self.save_downloaded_file(data)
            elif message:
                print(f"\n✅ 成功: {message}")
        else:
            error_msg = data.get('message', '未知错误')
            print(f"\n❌ 错误: {error_msg}")
            if DEBUG_MODE:
                print(f"[DEBUG] 完整错误数据: {data}")
            
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
    
    def save_stream_file(self, data):
        """保存流式传输的单个文件"""
        path = data.get('path', '')
        b64_data = data.get('data', '')
        index = data.get('index', 0)
        total = data.get('total', 0)
        size = data.get('size', 0)
        
        if not path or not b64_data:
            print(f"  [{index}] ⚠️  跳过空文件数据: path={path}, data_len={len(b64_data)}")
            return
        
        try:
            file_data = base64.b64decode(b64_data)
            
            # 创建时间戳目录（首次）
            if not self.stream_backup_dir:
                timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                self.stream_backup_dir = Path('downloads') / f'Documents_stream_{timestamp}'
                self.stream_backup_dir.mkdir(parents=True, exist_ok=True)
                print(f"\n📦 开始流式接收文件到: {self.stream_backup_dir}")
            
            local_path = self.stream_backup_dir / path
            local_path.parent.mkdir(parents=True, exist_ok=True)
            
            with open(local_path, 'wb') as f:
                f.write(file_data)
            
            # 更新接收计数
            self.download_file_count = index
            
            progress = f"[{index}/{total}]" if total > 0 else f"[{index}]"
            print(f"  {progress} ✅ {path} ({self.format_size(size)})")
            
            if DEBUG_MODE:
                print(f"[DEBUG] 已保存: {local_path}")
                
        except Exception as e:
            print(f"  [{index}] ❌ {path}: {e}")
            if DEBUG_MODE:
                import traceback
                print(f"[DEBUG] 错误堆栈: {traceback.format_exc()}")
    
    def save_compatible_file(self, data):
        """保存兼容模式下载的单个文件"""
        path = data.get('path', '')
        b64_data = data.get('data', '')
        size = data.get('size', 0)
        
        if not path or not b64_data:
            print(f"  ⚠️  跳过空文件数据: path={path}")
            return False
        
        try:
            file_data = base64.b64decode(b64_data)
            
            local_path = self.stream_backup_dir / path
            local_path.parent.mkdir(parents=True, exist_ok=True)
            
            with open(local_path, 'wb') as f:
                f.write(file_data)
            
            self.download_file_count += 1
            progress = f"[{self.download_file_count}/{self.download_expected_total}]"
            print(f"  {progress} ✅ {path} ({self.format_size(size)})")
            return True
                
        except Exception as e:
            print(f"  ❌ {path}: {e}")
            return False
    
    async def download_all_compatible(self):
        """兼容模式下载：先获取文件列表，再逐个下载"""
        import aiohttp
        
        # 重置状态
        self.compatible_download_in_progress = True
        self.compatible_file_list = None
        self.compatible_download_event = asyncio.Event()
        self.download_file_count = 0
        
        # 创建下载目录
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        self.stream_backup_dir = Path('downloads') / f'Documents_compatible_{timestamp}'
        self.stream_backup_dir.mkdir(parents=True, exist_ok=True)
        
        try:
            # 步骤1：发送 list_all 命令获取文件列表
            print("📋 步骤1: 获取设备文件列表...")
            await self.send_command({"command": "list_all"})
            
            # 等待响应（最多30秒）
            try:
                await asyncio.wait_for(self.compatible_download_event.wait(), timeout=30.0)
            except asyncio.TimeoutError:
                print("❌ 获取文件列表超时！")
                return
            
            if not self.compatible_file_list:
                print("❌ 未收到文件列表")
                return
            
            file_list = self.compatible_file_list
            total = len(file_list)
            self.download_expected_total = total
            
            if total == 0:
                print("📁 Documents 目录为空")
                return
            
            print(f"\n📦 步骤2: 开始逐个下载 {total} 个文件到: {self.stream_backup_dir}")
            
            success_count = 0
            fail_count = 0
            
            # 步骤2：逐个下载每个文件
            for i, file_path in enumerate(file_list):
                # 重置事件用于等待下一个响应
                self.compatible_download_event.clear()
                
                # 发送下载命令
                await self.send_command({"command": "download", "path": file_path})
                
                # 等待文件响应（最多60秒每个文件）
                try:
                    await asyncio.wait_for(self.compatible_download_event.wait(), timeout=60.0)
                    success_count += 1
                except asyncio.TimeoutError:
                    print(f"  ❌ [{i+1}/{total}] 下载超时: {file_path}")
                    fail_count += 1
                
                # 小延迟避免过快请求
                await asyncio.sleep(0.1)
            
            print(f"\n✅ 兼容模式下载完成！")
            print(f"   📊 总计: {total}, 成功: {success_count}, 失败: {fail_count}")
            print(f"💾 保存目录: {self.stream_backup_dir}")
            
        except Exception as e:
            print(f"❌ 兼容模式下载出错: {e}")
            if DEBUG_MODE:
                import traceback
                print(f"[DEBUG] 错误堆栈: {traceback.format_exc()}")
        finally:
            self.compatible_download_in_progress = False
            self.compatible_file_list = None
            self.compatible_download_event = None
            self.stream_backup_dir = None
            
    async def send_command(self, command):
        """发送命令到设备（支持 WebSocket 和 HTTP 模式）"""
        if self.device_connection:
            # WebSocket 模式：直接发送
            try:
                cmd_str = json.dumps(command)
                if DEBUG_MODE:
                    print(f"[DEBUG] WS发送命令: {cmd_str}")
                else:
                    print(f"[WS] 📤 发送命令: {command.get('command')}")
                await self.device_connection.send(cmd_str)
                return True
            except Exception as e:
                print(f"[ERROR] 发送命令失败: {e}")
                return False
        else:
            # HTTP 模式：放入队列
            if DEBUG_MODE:
                print(f"[DEBUG] HTTP队列命令: {command.get('command')}")
            else:
                print(f"[HTTP] 📦 队列命令: {command.get('command')}")
            self.command_queue.append(command)
            return True
            
    async def interactive_menu(self):
        """交互式菜单"""
        while True:
            await asyncio.sleep(0.1)  # 给 WebSocket/HTTP 处理留空间
            
            # 检测连接状态
            is_connected = False
            if self.device_connection:
                connection_type = "WebSocket"
                is_connected = True
            elif self.last_poll_time:
                # HTTP模式：检查最后轮询时间（10秒内算连接）
                time_diff = (datetime.now() - self.last_poll_time).total_seconds()
                if time_diff < 10:
                    connection_type = "HTTP 轮询"
                    is_connected = True
                else:
                    connection_type = "HTTP 轮询（已断开）"
            else:
                connection_type = "等待连接"
            
            if not is_connected:
                print(f"\n⏳ 等待设备连接... (模式: {connection_type})")
                await asyncio.sleep(5)
                continue
            
            # 如果正在进行传输，等待完成
            if self.download_in_progress:
                if self.download_expected_total > 0:
                    print(f"\r⏳ 下载中... 已接收 {self.download_file_count}/{self.download_expected_total} 个文件", end="", flush=True)
                else:
                    print(f"\r⏳ 下载中... 已接收 {self.download_file_count} 个文件", end="", flush=True)
                await asyncio.sleep(0.5)
                continue
            
            if self.upload_in_progress:
                remaining = len(self.upload_file_queue)
                print(f"\r⏳ 上传中... 剩余 {remaining} 个文件", end="", flush=True)
                await asyncio.sleep(0.5)
                continue
                
            print(f"\n{'='*60}")
            print(f"📱 {self.device_name} - ETOS LLM Studio 调试控制台")
            print(f"🔗 连接模式: {connection_type}")
            if not self.device_connection:
                print(f"📦 待发送命令: {len(self.command_queue)} 个")
            print(f"{'='*60}")
            print("1. 📂 列出设备目录")
            print("2. 📥 下载文件（设备→电脑）")
            print("3. 📤 上传文件（电脑→设备）")
            print("4. 🗑️  删除设备文件/目录")
            print("5. 📁 在设备创建目录")
            print("6. 📦 一键下载 Documents 目录")
            print("7. 📦 一键下载（兼容模式）")
            print("8. 🚀 一键上传覆盖 Documents")
            print("9. 🔄 刷新连接")
            print("0. 🚪 退出")
            print(f"{'='*60}")
            
            try:
                choice = await asyncio.to_thread(input, "请选择操作 [0-9]: ")
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
                    if self.device_connection:
                        await asyncio.sleep(1)
                    else:
                        print("⏳ 命令已入队，等待设备轮询...")
                    
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
                
                if self.device_connection:
                    # WebSocket模式：批量下载
                    await self.send_command({"command": "download_all"})
                    print("⏳ 等待设备打包和传输（WebSocket模式）...")
                    await asyncio.sleep(5)
                else:
                    # HTTP模式：流式下载
                    self.stream_backup_dir = None  # 重置流式目录
                    self.download_in_progress = True  # 开始下载
                    self.download_file_count = 0  # 重置计数
                    self.download_expected_total = 0  # 重置期望总数
                    await self.send_command({"command": "download_all"})
                    print("⏳ 命令已队列，等待设备传输文件...")
                    print("💡 提示：如果长时间没有进度，可能是设备端发送格式有问题")
            
            elif choice == '7':
                # 兼容模式：先获取文件列表，再逐个下载
                print("📦 兼容模式：准备下载整个 Documents 目录...")
                print("💡 此模式会先获取文件列表，然后逐个请求下载")
                await self.download_all_compatible()
            
            elif choice == '8':
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
                        
                        if self.device_connection:
                            # WebSocket模式：批量上传
                            print(f"\n📤 上传 {len(files)} 个文件到设备（批量模式）...")
                            await self.send_command({
                                "command": "upload_all",
                                "files": files
                            })
                            print("⏳ WebSocket模式：设备正在清空 Documents 并写入文件...")
                            await asyncio.sleep(5)
                        else:
                            # HTTP模式：先发送文件列表，设备主动请求文件
                            print(f"\n📤 上传 {len(files)} 个文件到设备（流式模式）...")
                            
                            # 准备文件数据字典（路径->数据）
                            self.upload_file_queue = {f["path"]: f["data"] for f in files}
                            self.upload_in_progress = True
                            
                            # 发送文件列表命令（只包含路径）
                            await self.send_command({
                                "command": "upload_list",
                                "paths": [f["path"] for f in files],
                                "total": len(files)
                            })
                            
                            print(f"✅ 已发送文件列表 ({len(files)} 个)")
                            print(f"   设备将主动请求每个文件数据")
                else:
                    print("❌ 目录不存在")
                    
            elif choice == '9':
                if self.device_connection:
                    await self.send_command({"command": "ping"})
                    await asyncio.sleep(0.5)
                    print("✅ 已发送 ping")
                else:
                    print("💡 HTTP模式下无需手动刷新")
                    
            elif choice == '0':
                print("👋 再见!")
                break
    
    # ========================================================================
    # HTTP 轮询端点
    # ========================================================================
    
    async def handle_http_ping(self, request):
        """HTTP Ping 测试端点"""
        return web.json_response({"status": "ok", "message": "pong", "server": "ETOS Debug Server"})
    
    async def handle_http_poll(self, request):
        """HTTP 轮询端点 - 设备获取命令（仅用于控制命令）"""
        # 更新轮询时间和设备信息
        self.last_poll_time = datetime.now()
        if self.device_name == "未知设备":
            client_ip = request.remote
            self.device_name = f"设备 {client_ip}"
            print(f"\n✅ 设备已连接 (HTTP 轮询): {client_ip}")
        
        # 检查流式上传是否完成
        if self.upload_in_progress and isinstance(self.upload_file_queue, dict) and not self.upload_file_queue:
            self.upload_in_progress = False
            print(f"[HTTP] ✅ 流式上传完成")
            return web.json_response({"command": "upload_complete"})
        
        # 处理普通命令队列
        if self.command_queue:
            command = self.command_queue.pop(0)
            if DEBUG_MODE:
                print(f"[DEBUG] HTTP轮询：返回命令 {command.get('command')}")
            else:
                print(f"[HTTP] 📤 发送命令: {command.get('command')}")
            return web.json_response(command)
        else:
            # 无命令，返回空
            return web.json_response({"command": "none"})
    
    async def handle_http_response(self, request):
        """HTTP 响应端点 - 设备提交响应"""
        try:
            data = await request.json()
            # 总是打印收到的响应类型，帮助调试
            if 'stream_complete' in data:
                print(f"[HTTP] 📥 收到完成信号: total={data.get('total', 0)}")
            elif 'path' in data and 'index' in data:
                print(f"[HTTP] 📥 接收文件 {data.get('index', 0)}/{data.get('total', '?')}: {data.get('path', 'unknown')}")
            elif DEBUG_MODE:
                print(f"[DEBUG] HTTP响应：{data.keys()}")
            self.handle_response(data)
            return web.json_response({"status": "ok"})
        except Exception as e:
            print(f"[ERROR] 处理HTTP响应失败: {e}")
            return web.json_response({"status": "error", "message": str(e)}, status=500)
    
    async def handle_http_fetch_file(self, request):
        """HTTP 文件请求端点 - 设备请求单个文件数据"""
        try:
            data = await request.json()
            path = data.get("path")
            
            if not path or not isinstance(self.upload_file_queue, dict):
                return web.json_response({"status": "error", "message": "无效请求"}, status=400)
            
            if path in self.upload_file_queue:
                file_data = self.upload_file_queue.pop(path)
                remaining = len(self.upload_file_queue)
                
                if DEBUG_MODE:
                    print(f"[DEBUG] 响应文件请求: {path} (剩余 {remaining})")
                else:
                    print(f"[HTTP] 📤 发送文件: {path} (剩余 {remaining})")
                
                return web.json_response({
                    "status": "ok",
                    "path": path,
                    "data": file_data,
                    "remaining": remaining
                })
            else:
                return web.json_response({"status": "error", "message": "文件不存在"}, status=404)
        except Exception as e:
            print(f"[ERROR] 处理文件请求失败: {e}")
            return web.json_response({"status": "error", "message": str(e)}, status=500)
    
    async def handle_http_fetch_file(self, request):
        """HTTP 文件请求端点 - 设备请求单个文件数据"""
        try:
            data = await request.json()
            path = data.get("path")
            
            if not path or not isinstance(self.upload_file_queue, dict):
                return web.json_response({"status": "error", "message": "无效请求"}, status=400)
            
            if path in self.upload_file_queue:
                file_data = self.upload_file_queue.pop(path)
                remaining = len(self.upload_file_queue)
                
                if DEBUG_MODE:
                    print(f"[DEBUG] 响应文件请求: {path} (剩余 {remaining})")
                else:
                    print(f"[HTTP] 📤 发送文件: {path} (剩余 {remaining})")
                
                return web.json_response({
                    "status": "ok",
                    "path": path,
                    "data": file_data,
                    "remaining": remaining
                })
            else:
                return web.json_response({"status": "error", "message": "文件不存在"}, status=404)
        except Exception as e:
            print(f"[ERROR] 处理文件请求失败: {e}")
            return web.json_response({"status": "error", "message": str(e)}, status=500)
    
    async def handle_openai_proxy(self, request):
        """处理 HTTP OpenAI 代理请求"""
        if request.path == '/v1/chat/completions' and request.method == 'POST':
            try:
                openai_data = await request.json()
                
                # 转发到设备
                await self.send_command({
                    "command": "openai_capture",
                    "request": openai_data
                })
                
                if DEBUG_MODE:
                    print(f"[DEBUG] OpenAI 请求已转发到设备")
                else:
                    print(f"📨 OpenAI 请求已转发到设备")
                    
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
        
    async def start_http_server(self):
        """启动 HTTP 服务器（轮询服务器 + OpenAI代理服务器）"""
        local_ip = get_local_ip()
        
        # ============================================================
        # HTTP 轮询服务器 (端口 7654) - 用于设备调试
        # ============================================================
        poll_app = web.Application(client_max_size=100*1024*1024)  # 100MB 限制
        poll_app.router.add_get('/ping', self.handle_http_ping)
        poll_app.router.add_post('/poll', self.handle_http_poll)
        poll_app.router.add_post('/response', self.handle_http_response)
        poll_app.router.add_post('/fetch_file', self.handle_http_fetch_file)  # 新增：文件请求端点
        poll_app.router.add_get('/', self.handle_http_ping)
        
        poll_runner = web.AppRunner(poll_app)
        await poll_runner.setup()
        poll_site = web.TCPSite(poll_runner, self.host, self.http_port)
        await poll_site.start()

        
        # ============================================================
        # OpenAI 代理服务器 (端口 8080) - 仅用于捕获 OpenAI 请求
        # ============================================================
        proxy_app = web.Application(client_max_size=10*1024*1024)  # 10MB 限制
        proxy_app.router.add_post('/v1/chat/completions', self.handle_openai_proxy)
        proxy_app.router.add_get('/', self.handle_openai_ping)
        
        proxy_runner = web.AppRunner(proxy_app)
        await proxy_runner.setup()
        proxy_site = web.TCPSite(proxy_runner, self.host, self.proxy_port)
        await proxy_site.start()
    
    async def handle_openai_ping(self, request):
        """OpenAI 代理服务器的 Ping 端点"""
        return web.json_response({
            "status": "ok", 
            "message": "ETOS OpenAI Proxy Server",
            "endpoint": "/v1/chat/completions"
        })
        
    async def run(self):
        """启动服务器"""
        local_ip = get_local_ip()
        
        print(f"""
╔══════════════════════════════════════════════════════════════╗
║  ETOS LLM Studio - 反向探针调试服务器                       ║
╚══════════════════════════════════════════════════════════════╝

🖥️  本机局域网IP: {local_ip}
📡 WebSocket 服务器: ws://{local_ip}:{self.ws_port} (推荐)
🌐 HTTP 轮询服务器: http://{local_ip}:{self.http_port} (备用)
🌐 HTTP 代理服务器: http://{local_ip}:{self.proxy_port}

💡 使用说明:
  1. 在设备上输入主机: {local_ip}
  2. WebSocket 端口: {self.ws_port} (模拟器首选)
  3. HTTP 轮询端口: {self.http_port} (真机备用)
  4. 设备连接后会自动进入操作菜单
  5. OpenAI API 设置为: http://{local_ip}:{self.proxy_port}

⚙️  调试模式: {"开启" if DEBUG_MODE else "关闭"} (修改文件顶部 DEBUG_MODE)

⏳ 等待设备连接...
        """)
        
        # 启动 HTTP 服务器
        await self.start_http_server()
        
        # 启动 WebSocket 服务器
        async with serve(self.handle_websocket, self.host, self.ws_port):
            # 启动交互菜单
            await self.interactive_menu()

def main():
    import sys
    
    host = '0.0.0.0'
    ws_port = 8765
    http_port = 7654
    proxy_port = 8080
    
    if len(sys.argv) > 1:
        ws_port = int(sys.argv[1])
    if len(sys.argv) > 2:
        http_port = int(sys.argv[2])
    if len(sys.argv) > 3:
        proxy_port = int(sys.argv[3])
        
    server = DebugServer(host, ws_port, http_port, proxy_port)
    
    try:
        asyncio.run(server.run())
    except KeyboardInterrupt:
        print("\n\n👋 服务器已停止")

if __name__ == '__main__':
    main()
