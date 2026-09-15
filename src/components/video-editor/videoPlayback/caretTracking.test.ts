import { describe, expect, it } from "vitest";
import type { CursorTelemetryPoint, ZoomRegion } from "../types";
import { normalizeCursorTelemetry } from "../timeline/zoomSuggestionUtils";
import { caretAtTime } from "./caretTracking";
import { createCursorFollowCameraState } from "./cursorFollowCamera";
import { resolveSceneZoomTarget } from "./sceneMotion";

const sample = (timeMs: number, x: number | null, mouseX = 0.2): CursorTelemetryPoint => ({
	timeMs,
	cx: mouseX,
	cy: 0.5,
	caret: x === null ? null : { cx: x, cy: 0.5 },
});
const region: ZoomRegion = {
	id: "typing",
	startMs: 0,
	endMs: 4000,
	depth: 4,
	focus: { cx: 0.5, cy: 0.5 },
	mode: "typing",
};

describe("caret capture playback", () => {
	it("interpolates the text caret without changing the mouse", () => {
		const samples = [sample(1000, 0.3), sample(1100, 0.5)];
		expect(caretAtTime(samples, 1050)).toEqual({ cx: 0.4, cy: 0.5 });
		expect(samples[0].cx).toBe(0.2);
	});
	it("does not use future, stale, or unavailable samples", () => {
		const samples = [sample(1000, 0.3), sample(1100, null)];
		expect(caretAtTime(samples, 999)).toBeNull();
		expect(caretAtTime(samples, 1100)).toBeNull();
		expect(caretAtTime([sample(1000, 0.3)], 1300)).toBeNull();
	});
	it("does not interpolate across a recording gap", () => {
		expect(caretAtTime([sample(1000, 0.3), sample(2000, 0.8)], 1050)?.cx).toBe(0.3);
	});
	it("rejects invalid coordinates and supports old recordings", () => {
		expect(caretAtTime([sample(0, Number.NaN)], 0)).toBeNull();
		expect(caretAtTime([sample(0, 2)], 0)).toBeNull();
		expect(caretAtTime([{ timeMs: 0, cx: 0.4, cy: 0.4 }], 0)).toBeNull();
	});
	it("preserves caret coordinates through editor normalization", () => {
		const samples = [sample(0, 0.3), sample(50, null), sample(100, 0.6)];
		expect(normalizeCursorTelemetry(samples, 1000).map((s) => s.caret)).toEqual(
			samples.map((s) => s.caret),
		);
	});
});

describe("typing camera", () => {
	it("pans continuously with typing while the mouse stays still", () => {
		const state = createCursorFollowCameraState();
		const samples = [sample(1000, 0.3), sample(1100, 0.4), sample(1200, 0.5)];
		const targets = [1000, 1100, 1200].map((timeMs) =>
			resolveSceneZoomTarget({
				zoomRegions: [region],
				timeMs,
				cursorTelemetry: samples,
				cursorFollowCamera: state,
			}),
		);
		expect(targets.map((t) => t.focus.cx)).toEqual([0.3, 0.4, 0.5]);
		expect(targets.map((t) => t.focus.cy)).toEqual([0.5, 0.5, 0.5]);
	});
	it("holds after typing ends, then follows an intentional mouse move", () => {
		const state = createCursorFollowCameraState();
		const samples = [sample(1000, 0.7), sample(1100, null), sample(1200, null, 0.1)];
		const target = (timeMs: number) =>
			resolveSceneZoomTarget({
				zoomRegions: [region],
				timeMs,
				cursorTelemetry: samples,
				cursorFollowCamera: state,
			}).focus.cx;
		expect(target(1000)).toBe(0.7);
		expect(target(1100)).toBe(0.7);
		expect(target(1200)).toBeLessThan(0.3);
	});
	it("does not change Auto or Manual behavior", () => {
		for (const mode of ["auto", "manual"] as const) {
			const evaluate = (caret: number | null) =>
				resolveSceneZoomTarget({
					zoomRegions: [{ ...region, mode }],
					timeMs: 1000,
					cursorTelemetry: [sample(1000, caret)],
					cursorFollowCamera: createCursorFollowCameraState(),
				});
			expect(evaluate(0.8)).toEqual(evaluate(null));
		}
	});
	it("falls back to mouse tracking for old recordings", () => {
		const evaluate = (mode: "auto" | "typing") => {
			const state = createCursorFollowCameraState();
			return [1000, 1100].map((timeMs) =>
				resolveSceneZoomTarget({
					zoomRegions: [{ ...region, mode }],
					timeMs,
					cursorTelemetry: [{ timeMs: 0, cx: 0.1, cy: 0.5 }],
					cursorFollowCamera: state,
				}),
			);
		};
		expect(evaluate("typing")).toEqual(evaluate("auto"));
	});
	it("re-evaluates the caret when seeking backwards", () => {
		const state = createCursorFollowCameraState();
		const samples = [sample(1000, 0.3), sample(1100, 0.7)];
		for (const timeMs of [1000, 1100, 1000]) {
			const target = resolveSceneZoomTarget({
				zoomRegions: [region],
				timeMs,
				cursorTelemetry: samples,
				cursorFollowCamera: state,
			});
			expect(target.focus.cx).toBe(timeMs === 1000 ? 0.3 : 0.7);
		}
	});
});
