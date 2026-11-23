/**
 * Page content extractor:
 *   1. Primary: `defuddle` (preserves code blocks, math, headings, clean Markdown)
 *   2. Fallback: `@mozilla/readability` + lightweight HTML-to-Markdown converter
 *   3. Final fallback: cleaned `document.body.innerText`
 */

import Defuddle from 'defuddle';
import { Readability } from '@mozilla/readability';
import { redactInlineSecrets } from './sanitizer';

export interface ExtractedArticle {
  title: string;
  markdown: string;
  summary: string;
  author?: string;
  site?: string;
  extractor: 'defuddle' | 'readability' | 'dom_fallback';
  wordCount: number;
}

const MAX_EXTRACTED_CHARS = 60_000;

function htmlToCleanMarkdown(html: string): string {
  // Fast deterministic HTML -> Markdown conversion preserving headings, lists, links, and code fences
  const parser = new DOMParser();
  const doc = parser.parseFromString(html, 'text/html');
  const walk = (node: Node): string => {
    if (node.nodeType === Node.TEXT_NODE) {
      return (node.textContent || '').replace(/\s+/g, ' ');
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const el = node as Element;
    const tag = el.tagName.toLowerCase();
    if (['script', 'style', 'noscript', 'svg', 'iframe'].includes(tag)) return '';
    if (tag === 'pre') {
      const code = el.textContent || '';
      const langMatch = (el.querySelector('code')?.className || '').match(/language-([a-z0-9_+-]+)/i);
      const lang = langMatch ? langMatch[1] : '';
      return `\n\n\`\`\`${lang}\n${code.trimEnd()}\n\`\`\`\n\n`;
    }
    if (tag === 'code') {
      return `\`${(el.textContent || '').trim()}\``;
    }
    const inner = Array.from(el.childNodes).map(walk).join('').trim();
    if (!inner) return '';
    switch (tag) {
      case 'h1':
        return `\n\n# ${inner}\n\n`;
      case 'h2':
        return `\n\n## ${inner}\n\n`;
      case 'h3':
        return `\n\n### ${inner}\n\n`;
      case 'h4':
      case 'h5':
      case 'h6':
        return `\n\n#### ${inner}\n\n`;
      case 'p':
      case 'div':
      case 'section':
      case 'article':
        return `\n\n${inner}\n\n`;
      case 'blockquote':
        return `\n\n> ${inner.replace(/\n+/g, '\n> ')}\n\n`;
      case 'li':
        return `\n- ${inner}`;
      case 'ul':
      case 'ol':
        return `\n${inner}\n\n`;
      case 'a': {
        const href = el.getAttribute('href');
        if (href && /^https?:\/\//i.test(href) && href !== inner) {
          return `[${inner}](${href})`;
        }
        return inner;
      }
      case 'br':
        return '\n';
      default:
        return inner;
    }
  };
  return walk(doc.body)
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function countWords(text: string): number {
  const cjk = (text.match(/[\u4e00-\u9fff]/g) || []).length;
  const latin = (text.replace(/[\u4e00-\u9fff]+/g, ' ').match(/[A-Za-z0-9_]+/g) || []).length;
  return cjk + latin;
}

function summarize(markdown: string): string {
  const firstPara = markdown
    .split(/\n{2,}/)
    .map((p) => p.replace(/^#+\s+/, '').trim())
    .find((p) => p.length >= 24 && !p.startsWith('```'));
  const base = (firstPara || markdown).replace(/\s+/g, ' ').trim();
  return base.length > 260 ? `${base.slice(0, 259)}…` : base;
}

export function extractPageArticle(doc: Document, url: string): ExtractedArticle {
  const fallbackTitle = (doc.title || url).trim().slice(0, 220);

  // 1. Primary: Defuddle
  try {
    const clone = doc.cloneNode(true) as Document;
    const defuddle = new Defuddle(clone, { url, markdown: true } as Record<string, unknown>);
    const res = defuddle.parse() as {
      title?: string;
      content?: string;
      description?: string;
      author?: string;
      site?: string;
    };
    if (res && typeof res.content === 'string' && res.content.trim().length >= 80) {
      const cleaned = res.content.includes('<') && !res.content.includes('\n#')
        ? htmlToCleanMarkdown(res.content)
        : res.content.trim();
      const safe = redactInlineSecrets(cleaned).slice(0, MAX_EXTRACTED_CHARS);
      return {
        title: (res.title || fallbackTitle).trim().slice(0, 220),
        markdown: safe,
        summary: redactInlineSecrets(res.description || summarize(safe)).slice(0, 280),
        author: res.author || undefined,
        site: res.site || undefined,
        extractor: 'defuddle',
        wordCount: countWords(safe),
      };
    }
  } catch {
    // Fall through to Readability
  }

  // 2. Fallback: Mozilla Readability
  try {
    const clone = doc.cloneNode(true) as Document;
    const article = new Readability(clone).parse();
    if (article && article.content && article.content.trim().length >= 60) {
      const md = redactInlineSecrets(htmlToCleanMarkdown(article.content)).slice(
        0,
        MAX_EXTRACTED_CHARS,
      );
      if (md.length >= 40) {
        return {
          title: (article.title || fallbackTitle).trim().slice(0, 220),
          markdown: md,
          summary: redactInlineSecrets(article.excerpt || summarize(md)).slice(0, 280),
          author: article.byline || undefined,
          site: article.siteName || undefined,
          extractor: 'readability',
          wordCount: countWords(md),
        };
      }
    }
  } catch {
    // Fall through to plain DOM fallback
  }

  // 3. Final fallback: cleaned body text
  const rawText = (doc.body?.textContent || '')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  const safe = redactInlineSecrets(rawText).slice(0, MAX_EXTRACTED_CHARS);
  return {
    title: fallbackTitle,
    markdown: safe,
    summary: summarize(safe),
    extractor: 'dom_fallback',
    wordCount: countWords(safe),
  };
}
