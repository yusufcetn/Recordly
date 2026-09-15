import { normalizeCaret } from "@/lib/caret";
import type { CursorTelemetryPoint, ZoomFocus } from "../types";

/** Do not interpolate across focus loss, selections, or missing capture data. */
export function caretAtTime(samples: CursorTelemetryPoint[], timeMs: number): ZoomFocus | null {
	let low = 0;
	let high = samples.length;
	while (low < high) {
		const mid = (low + high) >>> 1;
		if (samples[mid].timeMs <= timeMs) low = mid + 1;
		else high = mid;
	}
	const previous = samples[low - 1];
	if (!previous || timeMs - previous.timeMs > 250) return null;
	const caret = normalizeCaret(previous.caret);
	if (!caret) return null;
	const next = samples[low];
	const nextCaret = normalizeCaret(next?.caret);
	if (!next || !nextCaret || next.timeMs - previous.timeMs > 150) return caret;
	const progress = (timeMs - previous.timeMs) / Math.max(1, next.timeMs - previous.timeMs);
	return {
		cx: caret.cx + (nextCaret.cx - caret.cx) * progress,
		cy: caret.cy + (nextCaret.cy - caret.cy) * progress,
	};
}
