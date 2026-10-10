// Windows region capture: the frozen screen is shown full-size; drag to select, Esc cancels.
import { useEffect, useRef, useState } from "react";
import { api } from "../lib/ipc";

type Point = { x: number; y: number };

export function Overlay() {
  const [image, setImage] = useState<string | null>(null);
  const [start, setStart] = useState<Point | null>(null);
  const [end, setEnd] = useState<Point | null>(null);
  const done = useRef(false);

  useEffect(() => {
    api.overlayImage().then(setImage);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && finish(null);
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const finish = (rect: { x: number; y: number; width: number; height: number } | null) => {
    if (done.current) return;
    done.current = true;
    api.overlayFinish(rect);
  };
  const rect = start && end
    ? { x: Math.min(start.x, end.x), y: Math.min(start.y, end.y), width: Math.abs(end.x - start.x), height: Math.abs(end.y - start.y) }
    : null;

  return (
    <div
      style={{ position: "fixed", inset: 0, cursor: "crosshair", background: image ? `url(${image}) 0 0 / 100% 100%` : "transparent" }}
      onMouseDown={(e) => { setStart({ x: e.clientX, y: e.clientY }); setEnd({ x: e.clientX, y: e.clientY }); }}
      onMouseMove={(e) => start && setEnd({ x: e.clientX, y: e.clientY })}
      onMouseUp={() => finish(rect && rect.width > 3 && rect.height > 3 ? rect : null)}
    >
      <div style={{ position: "absolute", inset: 0, background: "rgba(0,0,0,0.35)", clipPath: rect ? hole(rect) : undefined }} />
      {rect && <div style={{ position: "absolute", left: rect.x, top: rect.y, width: rect.width, height: rect.height, outline: "1.5px solid white", boxShadow: "0 0 0 1px rgba(0,0,0,0.4)" }} />}
      {!start && (
        <div style={{ position: "absolute", top: 24, left: "50%", transform: "translateX(-50%)", padding: "6px 12px", borderRadius: 8, background: "rgba(0,0,0,0.7)", color: "white", fontSize: 13 }}>
          설명받을 영역을 드래그하세요 · Esc 취소
        </div>
      )}
    </div>
  );
}

// Darkens everything except the selection.
function hole(r: { x: number; y: number; width: number; height: number }) {
  const outer = "0 0, 100% 0, 100% 100%, 0 100%, 0 0";
  const inner = `${r.x}px ${r.y}px, ${r.x}px ${r.y + r.height}px, ${r.x + r.width}px ${r.y + r.height}px, ${r.x + r.width}px ${r.y}px, ${r.x}px ${r.y}px`;
  return `polygon(evenodd, ${outer}, ${inner})`;
}
