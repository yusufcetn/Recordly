import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { ensureNativeCursorMonitorBinary } from "../paths/binaries";

const execFileAsync = promisify(execFile);

export type CursorHelperPermissionName = "accessibility" | "input-events";

export interface CursorHelperPermissionStatus {
	success: boolean;
	/** Caret tracking reads the focused text field through the Accessibility API. */
	accessibility: boolean;
	/** Click telemetry, which drives auto-zoom suggestions and click effects. */
	inputEvents: boolean;
	error?: string;
}

export function parseCursorHelperPermissionLine(
	line: string,
): { name: CursorHelperPermissionName; granted: boolean } | null {
	const match = line.trim().match(/^PERMISSION:(accessibility|input-events):([01])$/);
	return match
		? { name: match[1] as CursorHelperPermissionName, granted: match[2] === "1" }
		: null;
}

export function parseCursorHelperPermissionOutput(stdout: string): CursorHelperPermissionStatus {
	const granted = new Map<CursorHelperPermissionName, boolean>();
	for (const line of stdout.split(/\r?\n/)) {
		const permission = parseCursorHelperPermissionLine(line);
		if (permission) granted.set(permission.name, permission.granted);
	}

	if (!granted.has("accessibility") || !granted.has("input-events")) {
		return {
			success: false,
			accessibility: false,
			inputEvents: false,
			error: "Cursor helper did not report its permissions",
		};
	}

	return {
		success: true,
		accessibility: granted.get("accessibility") === true,
		inputEvents: granted.get("input-events") === true,
	};
}

/**
 * Ask the cursor helper itself which permissions TCC grants it. This can differ
 * from the app's own Accessibility check, so a passing app check alone does not
 * mean clicks and the text caret will be captured.
 */
export async function checkCursorHelperPermissions(): Promise<CursorHelperPermissionStatus> {
	if (process.platform !== "darwin") {
		return { success: true, accessibility: true, inputEvents: true };
	}

	try {
		const helperPath = await ensureNativeCursorMonitorBinary();
		const { stdout } = await execFileAsync(helperPath, ["--check-permissions"], {
			encoding: "utf8",
			timeout: 5000,
		});
		return parseCursorHelperPermissionOutput(stdout);
	} catch (error) {
		return { success: false, accessibility: false, inputEvents: false, error: String(error) };
	}
}
