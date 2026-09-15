import { describe, expect, it, vi } from "vitest";
vi.mock("../paths/binaries", () => ({ ensureNativeCursorMonitorBinary: vi.fn() }));
import {
	parseCursorHelperPermissionLine,
	parseCursorHelperPermissionOutput,
} from "./helperPermissions";

describe("cursor helper permissions", () => {
	it("parses the helper's permission report", () => {
		expect(
			parseCursorHelperPermissionOutput(
				"PERMISSION:accessibility:0\nPERMISSION:input-events:1\n",
			),
		).toEqual({ success: true, accessibility: false, inputEvents: true });
	});

	it("fails instead of assuming access when the report is incomplete", () => {
		expect(parseCursorHelperPermissionOutput("PERMISSION:accessibility:1\n")).toMatchObject({
			success: false,
			accessibility: false,
			inputEvents: false,
		});
	});

	it("ignores unrelated helper output", () => {
		expect(parseCursorHelperPermissionLine("CARET:none")).toBeNull();
		expect(parseCursorHelperPermissionLine("PERMISSION:accessibility:1")).toEqual({
			name: "accessibility",
			granted: true,
		});
	});
});
