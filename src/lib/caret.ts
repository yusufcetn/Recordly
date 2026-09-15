/** Validate rather than clamp: off-screen or malformed caret data is unavailable. */
export function normalizeCaret(value: unknown): { cx: number; cy: number } | null {
	if (!value || typeof value !== "object") return null;
	const { cx, cy } = value as { cx?: unknown; cy?: unknown };
	return typeof cx === "number" &&
		Number.isFinite(cx) &&
		cx >= 0 &&
		cx <= 1 &&
		typeof cy === "number" &&
		Number.isFinite(cy) &&
		cy >= 0 &&
		cy <= 1
		? { cx, cy }
		: null;
}
