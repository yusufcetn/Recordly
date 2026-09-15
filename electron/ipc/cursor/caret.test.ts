import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("../state", () => ({
	selectedSource: { id: "screen:1", display_id: "1" },
	selectedWindowBounds: null,
}));
vi.mock("../utils", () => ({
	getScreen: () => ({
		getAllDisplays: () => [{ id: 1, bounds: { x: 0, y: 0, width: 1000, height: 800 } }],
	}),
}));
import {
	acceptCaretMessage,
	getCapturedCaret,
	normalizeCaretToBounds,
	resetCaretCapture,
} from "./caret";

beforeEach(resetCaretCapture);
describe("native caret capture", () => {
	it("normalizes screen points and expires a stopped helper", () => {
		expect(acceptCaretMessage("CARET:500:200", 1000)).toBe(true);
		expect(getCapturedCaret(1100)).toEqual({ cx: 0.5, cy: 0.25 });
		expect(getCapturedCaret(1300)).toBeNull();
	});
	it("clears immediately on focus loss or malformed data", () => {
		for (const line of ["CARET:none", "CARET:NaN:4", "CARET:1:Infinity", "CARET:1:2:3"]) {
			acceptCaretMessage("CARET:500:200", 1000);
			acceptCaretMessage(line, 1010);
			expect(getCapturedCaret(1010)).toBeNull();
		}
	});
	it("handles a secondary display with a negative origin", () => {
		expect(
			normalizeCaretToBounds(
				{ x: -500, y: 100 },
				{ x: -1000, y: -100, width: 1000, height: 800 },
			),
		).toEqual({ cx: 0.5, cy: 0.25 });
	});
	it("ignores a caret outside the selected window or display", () => {
		expect(
			normalizeCaretToBounds({ x: 900, y: 100 }, { x: 0, y: 0, width: 800, height: 600 }),
		).toBeNull();
	});
});
