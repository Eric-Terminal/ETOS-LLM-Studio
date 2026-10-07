import Foundation

/// 移动端与桌面端共用 Widget 的主题变量和画布，平台视图只负责 WebKit 生命周期。
public enum ToolWidgetHTMLDocumentFactory {
    public static func document(widgetCode: String) -> String {
        """
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <style id="et-widget-host-style">
    :root {
      color-scheme: light dark;
      --color-background-primary: #FFFFFF;
      --color-background-secondary: #F2F2F7;
      --color-background-tertiary: #FFFFFF;
      --color-text-primary: #1C1C1E;
      --color-text-secondary: #3C3C43;
      --color-text-tertiary: #8E8E93;
      --color-text-info: #0A84FF;
      --color-border-tertiary: rgba(60, 60, 67, 0.16);
      --color-border-secondary: rgba(60, 60, 67, 0.3);
      --border-radius-md: 8px;
      --border-radius-lg: 12px;
      --border-radius-xl: 16px;
      --font-sans: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
      --font-serif: Georgia, 'Times New Roman', serif;
      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --color-background-primary: #1C1C1E;
        --color-background-secondary: #2C2C2E;
        --color-background-tertiary: #1C1C1E;
        --color-text-primary: #FFFFFF;
        --color-text-secondary: #EBEBF5;
        --color-text-tertiary: #8E8E93;
        --color-text-info: #5AC8FA;
        --color-border-tertiary: rgba(235, 235, 245, 0.16);
        --color-border-secondary: rgba(235, 235, 245, 0.3);
      }
    }
    html, body {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      min-height: 0;
      background: transparent;
      overflow: hidden;
    }
    body {
      position: relative;
    }
    #et-widget-host {
      width: 100%;
      height: 100%;
      max-width: 100%;
      box-sizing: border-box;
      overflow: hidden;
    }
    #et-widget-root {
      width: 100%;
      height: 100%;
      min-width: 0;
      max-width: 100%;
      margin: 0;
      box-sizing: border-box;
      overflow: hidden;
    }
  </style>
</head>
<body>
  <div id="et-widget-host">
    <div id="et-widget-root">
\(widgetCode)
    </div>
  </div>
</body>
</html>
"""
    }
}

public struct CompletedToolWidget: Identifiable, Sendable {
    public let id = UUID()
    public let payload: ToolWidgetPayload
    public let html: String

    /// 只显示已完成工具的结果；审批中的参数和失败结果不能提前执行网页脚本。
    public init?(message: ChatMessage) {
        guard message.role == .tool, !message.isReceivingStream else { return nil }
        let result: String
        if let call = message.toolCalls?.first {
            guard call.toolName == AppToolKind.showWidget.toolName,
                  call.resultDisposition == nil || call.resultDisposition == .completed else { return nil }
            result = call.result ?? message.content
        } else {
            result = message.content
        }
        guard let payload = ToolWidgetPayloadParser.parse(from: result) else { return nil }
        self.payload = payload
        html = ToolWidgetHTMLDocumentFactory.document(widgetCode: payload.widgetCode)
    }
}
