import { selectedSource, selectedWindowBounds } from "../state";
import { getScreen } from "../utils";

type Point = { x: number; y: number };
let latestCaret: (Point & { updatedAt: number }) | null = null;

export function acceptCaretMessage(line: string, nowMs = Date.now()): boolean {
	if (!line.startsWith("CARET:")) return false;
	const parts = line.split(":");
	const x = Number(parts[1]);
	const y = Number(parts[2]);
	latestCaret =
		parts.length === 3 && Number.isFinite(x) && Number.isFinite(y)
			? { x, y, updatedAt: nowMs }
			: null;
	return true;
}

export function resetCaretCapture() {
	latestCaret = null;
}

export function normalizeCaretToBounds(
	point: Point,
	bounds: Point & { width: number; height: number },
) {
	if (bounds.width <= 0 || bounds.height <= 0) return null;
	const cx = (point.x - bounds.x) / bounds.width;
	const cy = (point.y - bounds.y) / bounds.height;
	// A focused field on another display/window must not pin the recording edge.
	return Number.isFinite(cx) && Number.isFinite(cy) && cx >= 0 && cx <= 1 && cy >= 0 && cy <= 1
		? { cx, cy }
		: null;
}

export function getCapturedCaret(nowMs = Date.now()) {
	if (!latestCaret || nowMs - latestCaret.updatedAt > 250) return null;
	if (selectedSource?.id?.startsWith("window:")) {
		return selectedWindowBounds
			? normalizeCaretToBounds(latestCaret, selectedWindowBounds)
			: null;
	}
	const display = getScreen()
		.getAllDisplays()
		.find((d) => d.id === Number(selectedSource?.display_id));
	return display ? normalizeCaretToBounds(latestCaret, display.bounds) : null;
}
