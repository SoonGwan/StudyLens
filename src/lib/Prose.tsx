// Renders the prose parts of an answer: headings, lists, quotes and inline emphasis.
// Built as React elements (never raw HTML), so model output can't inject markup.
import type { ReactNode } from "react";
import { api } from "./ipc";

type Line =
  | { kind: "heading"; level: number; text: string }
  | { kind: "bullet"; ordered: string | null; indent: number; text: string }
  | { kind: "quote"; text: string }
  | { kind: "rule" }
  | { kind: "text"; text: string }
  | { kind: "blank" };

export function parseLines(source: string): Line[] {
  return source.split("\n").map((raw): Line => {
    const line = raw.replace(/\r$/, "");
    if (!line.trim()) return { kind: "blank" };
    let m = /^(#{1,6})\s+(.*)$/.exec(line);
    if (m) return { kind: "heading", level: m[1].length, text: m[2] };
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) return { kind: "rule" };
    m = /^(\s*)(?:[-*+]|(\d+)[.)])\s+(.*)$/.exec(line);
    if (m) return { kind: "bullet", indent: Math.floor(m[1].length / 2), ordered: m[2] ?? null, text: m[3] };
    m = /^>\s?(.*)$/.exec(line);
    if (m) return { kind: "quote", text: m[1] };
    return { kind: "text", text: line };
  });
}

export function Prose({ text }: { text: string }) {
  const lines = parseLines(text);
  const out: ReactNode[] = [];
  let paragraph: string[] = [];
  const flush = () => {
    if (paragraph.length) out.push(<p key={out.length}>{inline(paragraph.join("\n"))}</p>);
    paragraph = [];
  };
  for (const line of lines) {
    if (line.kind === "text") {
      paragraph.push(line.text);
      continue;
    }
    flush();
    const key = out.length;
    switch (line.kind) {
      case "heading":
        out.push(<div key={key} className={`h h${Math.min(line.level, 3)}`}>{inline(line.text)}</div>);
        break;
      case "bullet":
        out.push(
          <div key={key} className="li" style={{ paddingLeft: 18 + line.indent * 16 }}>
            <span className="marker">{line.ordered ? `${line.ordered}.` : "•"}</span>
            {inline(line.text)}
          </div>,
        );
        break;
      case "quote":
        out.push(<blockquote key={key}>{inline(line.text)}</blockquote>);
        break;
      case "rule":
        out.push(<hr key={key} />);
        break;
      case "blank":
        break;
    }
  }
  flush();
  return <div className="prose selectable">{out}</div>;
}

const INLINE = /(`[^`\n]+`)|(\*\*[^*\n]+\*\*|__[^_\n]+__)|(\*[^*\n]+\*|_[^_\n]+_)|(\[[^\]\n]+\]\((https?:\/\/[^)\s]+)\))/g;

export function inline(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let last = 0;
  for (const match of text.matchAll(INLINE)) {
    const index = match.index ?? 0;
    if (index > last) nodes.push(text.slice(last, index));
    const [token, code, bold, italic, link, url] = match;
    const key = nodes.length;
    if (code) nodes.push(<code key={key}>{code.slice(1, -1)}</code>);
    else if (bold) nodes.push(<strong key={key}>{inline(bold.slice(2, -2))}</strong>);
    else if (italic) nodes.push(<em key={key}>{inline(italic.slice(1, -1))}</em>);
    else if (link && url) {
      const label = link.slice(1, link.indexOf("]("));
      nodes.push(
        <a key={key} href={url} onClick={(e) => { e.preventDefault(); api.openLink(url); }}>
          {label}
        </a>,
      );
    } else nodes.push(token);
    last = index + token.length;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes;
}
