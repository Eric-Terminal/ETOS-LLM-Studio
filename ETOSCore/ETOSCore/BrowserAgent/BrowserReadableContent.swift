// ============================================================================
// BrowserReadableContent.swift
// ============================================================================
// ETOS LLM Studio
//
// 正文提取采用轻量候选评分，不依赖或复制第三方 Readability 实现。
// ============================================================================

import Foundation

enum BrowserReadableContent {
    static let script = """
    (() => {
      const candidates = Array.from(document.querySelectorAll('article,main,[role="main"],section,div'));
      let best = document.body;
      let bestScore = -Infinity;
      for (const node of candidates.slice(0, 2000)) {
        const style = getComputedStyle(node);
        if (style.display === 'none' || style.visibility === 'hidden') continue;
        const text = (node.innerText || '').trim();
        if (text.length < 200) continue;
        const paragraphs = node.querySelectorAll('p').length;
        const links = Array.from(node.querySelectorAll('a')).reduce((sum, link) => sum + (link.innerText || '').length, 0);
        const density = links / Math.max(text.length, 1);
        const hint = ((node.id || '') + ' ' + (typeof node.className === 'string' ? node.className : '')).toLowerCase();
        const positive = /article|content|post|story|entry|main/.test(hint) ? 500 : 0;
        const negative = /nav|menu|sidebar|footer|comment|advert|promo/.test(hint) ? 900 : 0;
        const score = Math.log2(text.length + 1) * 120 + paragraphs * 45 + positive - density * 1200 - negative;
        if (score > bestScore) { best = node; bestScore = score; }
      }
      const clone = best.cloneNode(true);
      clone.querySelectorAll('script,style,noscript,nav,aside,footer,form,button,[aria-hidden="true"]').forEach(node => node.remove());
      const sourceText = (clone.innerText || clone.textContent || '').replace(/\\n{3,}/g, '\\n\\n').trim();
      const links = Array.from(clone.querySelectorAll('a[href]'))
        .map(node => { try { return new URL(node.href, location.href).href; } catch (_) { return null; } })
        .filter(Boolean);
      const author = document.querySelector('[rel="author"],meta[name="author"],meta[property="article:author"]');
      const date = document.querySelector('time[datetime],meta[property="article:published_time"],meta[name="date"]');
      const authorValue = author?.content || author?.innerText || null;
      const dateValue = date?.dateTime || date?.content || date?.innerText || null;
      return {
        title: document.querySelector('meta[property="og:title"]')?.content || document.title || '',
        byline: authorValue ? String(authorValue).trim().slice(0, 500) : null,
        publishedAt: dateValue ? String(dateValue).trim().slice(0, 200) : null,
        text: sourceText.slice(0, 50000),
        links: Array.from(new Set(links)).slice(0, 100),
        wasTruncated: sourceText.length > 50000 || links.length > 100
      };
    })()
    """
}
