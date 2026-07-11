// ============================================================================
// RoleplayHelperScriptDocument.swift
// ============================================================================
// ETOS LLM Studio
//
// 把酒馆助手角色脚本包装为可在 iOS/watchOS WebView 中执行的 ES Module。
// ============================================================================

import Foundation

public enum RoleplayHelperScriptDocument {
    public static func source(_ content: String) -> String {
        let encoded = Data(content.utf8).base64EncodedString()
        return #"""
<script>
(async function () {
  const binary = atob('\#(encoded)');
  const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
  let source = new TextDecoder().decode(bytes);
  source = source.replace(
    /^\s*import\s+['"]https?:\/\/[^'"]*\/MagicalAstrogy\/MagVarUpdate(?:@[^\/'"]+)?\/artifact\/bundle\.js['"]\s*;?\s*$/gmi,
    ''
  );
  try {
    if (/\bz\s*\./.test(source) && !window.z) {
      window.z = await import('https://testingcf.jsdelivr.net/npm/zod@4.3.6/+esm');
    }
    if (/^\s*(?:import|export)\s/m.test(source)) {
      const moduleURL = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
      try { await import(moduleURL); }
      finally { URL.revokeObjectURL(moduleURL); }
    } else {
      (0, eval)(source);
    }
  } catch (error) {
    console.error('[ETOS 酒馆助手脚本]', error);
  }
})();
</script>
"""#
    }
}
