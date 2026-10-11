/** Time-aware caption only; clicking it opens the real macOS Focus settings. */
export function focusDurationLabel(hour: number): string {
  if (hour < 6) return "오늘 아침까지";
  if (hour < 18) return "오늘 저녁까지";
  return "내일 아침까지";
}
