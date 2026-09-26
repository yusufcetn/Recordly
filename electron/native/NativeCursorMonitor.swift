import Foundation
import AppKit
import ApplicationServices

// Force AppKit initialization so cursor images are populated in CLI context
let _ = NSApplication.shared

func knownCursorCandidates() -> [(String, NSCursor)] {
	var candidates: [(String, NSCursor)] = [
		("arrow", .arrow),
		("text", .iBeam),
		("pointer", .pointingHand),
		("pointer", .dragCopy),
		("pointer", .dragLink),
		("pointer", .contextualMenu),
		("crosshair", .crosshair),
		("open-hand", .openHand),
		("closed-hand", .closedHand),
		("resize-ew", .resizeLeft),
		("resize-ew", .resizeRight),
		("resize-ew", .resizeLeftRight),
		("resize-ns", .resizeUp),
		("resize-ns", .resizeDown),
		("resize-ns", .resizeUpDown),
		("not-allowed", .operationNotAllowed),
	]

	if #available(macOS 10.13, *) {
		candidates.append(("text", .iBeamCursorForVerticalLayout))
	}

	return candidates
}

let signatureAcceptanceThreshold = 12000
let relaxedSignatureAcceptanceThresholds: [String: Int] = [
	"text": 28000,
	"crosshair": 32000,
]
let strictSignatureAcceptanceThresholds: [String: Int] = [
	"open-hand": 3200,
	"closed-hand": 3200,
]

let systemWideElement = AXUIElementCreateSystemWide()
let totalScreenHeight = NSScreen.screens.reduce(CGFloat(0)) { max($0, $1.frame.maxY) }
let axEditableAttribute = "AXEditable"
let axLinkRole = "AXLink"

struct CursorSignature {
	let aspectRatio: Double
	let hotspotXRatio: Double
	let hotspotYRatio: Double
	let shapeSamples: [UInt8]
}

func signature(for cursor: NSCursor, sampleSize: Int = 32) -> CursorSignature? {
	let image = cursor.image
	let sourceSize = image.size
	guard sourceSize.width > 0, sourceSize.height > 0 else {
		return nil
	}

	guard let bitmap = NSBitmapImageRep(
		bitmapDataPlanes: nil,
		pixelsWide: sampleSize,
		pixelsHigh: sampleSize,
		bitsPerSample: 8,
		samplesPerPixel: 4,
		hasAlpha: true,
		isPlanar: false,
		colorSpaceName: .deviceRGB,
		bytesPerRow: 0,
		bitsPerPixel: 0
	) else {
		return nil
	}

	bitmap.size = NSSize(width: sampleSize, height: sampleSize)

	NSGraphicsContext.saveGraphicsState()
	guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
		NSGraphicsContext.restoreGraphicsState()
		return nil
	}

	NSGraphicsContext.current = context
	context.imageInterpolation = .high

	let scale = min(CGFloat(sampleSize) / sourceSize.width, CGFloat(sampleSize) / sourceSize.height)
	let drawWidth = sourceSize.width * scale
	let drawHeight = sourceSize.height * scale
	let drawRect = NSRect(
		x: (CGFloat(sampleSize) - drawWidth) / 2,
		y: (CGFloat(sampleSize) - drawHeight) / 2,
		width: drawWidth,
		height: drawHeight
	)

	image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
	context.flushGraphics()
	NSGraphicsContext.restoreGraphicsState()

	guard let data = bitmap.bitmapData else {
		return nil
	}

	var alphaSamples: [UInt8] = []
	alphaSamples.reserveCapacity(sampleSize * sampleSize)
	let bytesPerRow = bitmap.bytesPerRow

	for y in 0..<sampleSize {
		for x in 0..<sampleSize {
			let offset = y * bytesPerRow + x * 4
			let alpha = data[offset + 3]
			alphaSamples.append(alpha > 24 ? 255 : 0)
		}
	}

	let hotspot = cursor.hotSpot
	return CursorSignature(
		aspectRatio: Double(sourceSize.width / max(1, sourceSize.height)),
		hotspotXRatio: Double(hotspot.x / max(1, sourceSize.width)),
		hotspotYRatio: Double(hotspot.y / max(1, sourceSize.height)),
		shapeSamples: alphaSamples
	)
}

func signatureScore(_ lhs: CursorSignature, _ rhs: CursorSignature) -> Int {
	let count = min(lhs.shapeSamples.count, rhs.shapeSamples.count)
	var imageDifference = 0
	for index in 0..<count {
		imageDifference += abs(Int(lhs.shapeSamples[index]) - Int(rhs.shapeSamples[index]))
	}

	let aspectPenalty = Int(abs(lhs.aspectRatio - rhs.aspectRatio) * 1800)
	let hotspotPenalty = Int((abs(lhs.hotspotXRatio - rhs.hotspotXRatio) + abs(lhs.hotspotYRatio - rhs.hotspotYRatio)) * 2200)
	return imageDifference + aspectPenalty + hotspotPenalty
}

let knownCursorSignatures: [(String, CursorSignature)] = knownCursorCandidates().compactMap { entry in
	guard let cursorSignature = signature(for: entry.1) else {
		return nil
	}

	return (entry.0, cursorSignature)
}

func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
	var value: CFTypeRef?
	let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
	guard error == .success else {
		return nil
	}

	return value as? String
}

func attributeBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
	var value: CFTypeRef?
	let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
	guard error == .success else {
		return nil
	}

	return value as? Bool
}

func actionNames(_ element: AXUIElement) -> [String] {
	var names: CFArray?
	let error = AXUIElementCopyActionNames(element, &names)
	guard error == .success, let actions = names as? [String] else {
		return []
	}

	return actions
}

func currentElement() -> AXUIElement? {
	guard let location = CGEvent(source: nil)?.location else {
		return nil
	}

	var element: AXUIElement?
	let y = totalScreenHeight > 0 ? totalScreenHeight - location.y : location.y
	let error = AXUIElementCopyElementAtPosition(systemWideElement, Float(location.x), Float(y), &element)
	guard error == .success else {
		return nil
	}

	return element
}

func focusedElement() -> AXUIElement? {
	var value: CFTypeRef?
	let error = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &value)
	guard error == .success, let value else {
		return nil
	}

	return unsafeBitCast(value, to: AXUIElement.self)
}

func parentElement(of element: AXUIElement) -> AXUIElement? {
	var value: CFTypeRef?
	let error = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
	guard error == .success, let value else {
		return nil
	}

	return unsafeBitCast(value, to: AXUIElement.self)
}

func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
	var value: CFTypeRef?
	return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
}

func ancestorChain(startingAt element: AXUIElement?, maxDepth: Int = 4) -> [AXUIElement] {
	guard let element else {
		return []
	}

	var elements: [AXUIElement] = [element]
	var current = element
	var depth = 0

	while depth < maxDepth, let parent = parentElement(of: current) {
		elements.append(parent)
		current = parent
		depth += 1
	}

	return elements
}

func metadataString(for element: AXUIElement) -> String {
	return [
		attributeString(element, kAXRoleAttribute),
		attributeString(element, kAXSubroleAttribute),
		attributeString(element, kAXRoleDescriptionAttribute),
		attributeString(element, kAXDescriptionAttribute),
		attributeString(element, kAXHelpAttribute),
		attributeString(element, kAXTitleAttribute),
	]
	.compactMap { $0?.lowercased() }
	.joined(separator: " ")
}

func elementLooksTextual(_ element: AXUIElement) -> Bool {
	let role = attributeString(element, kAXRoleAttribute)
	let subrole = attributeString(element, kAXSubroleAttribute)
	let editable = attributeBool(element, axEditableAttribute)
	let metadata = metadataString(for: element)
	let actions = actionNames(element)

	let textRoles: Set<String> = [
		kAXTextFieldRole as String,
		kAXTextAreaRole as String,
		kAXComboBoxRole as String,
		kAXSearchFieldSubrole as String,
	]

	if editable == true || textRoles.contains(role ?? "") || textRoles.contains(subrole ?? "") {
		return true
	}

	if metadata.contains("text field")
		|| metadata.contains("search field")
		|| metadata.contains("editor")
		|| metadata.contains("insertion point")
		|| metadata.contains("caret")
		|| metadata.contains("source editor") {
		return true
	}

	return hasAttribute(element, kAXSelectedTextRangeAttribute as String)
		|| hasAttribute(element, kAXNumberOfCharactersAttribute as String)
		|| (actions.contains(kAXPressAction as String) && metadata.contains("text"))
}

func accessibilityCursorMatch() -> String? {
	let hoveredChain = ancestorChain(startingAt: currentElement())
	let focusedChain = ancestorChain(startingAt: focusedElement())

	for element in hoveredChain + focusedChain {
		if elementLooksTextual(element) {
			return "text"
		}
	}

	guard let element = hoveredChain.first else {
		return nil
	}

	let role = attributeString(element, kAXRoleAttribute)
	let enabled = attributeBool(element, kAXEnabledAttribute)
	let actions = actionNames(element)
	let metadata = hoveredChain
		.map { metadataString(for: $0) }
		.filter { !$0.isEmpty }
		.joined(separator: " ")
	if metadata.contains("crosshair") || metadata.contains("cross hair") || metadata.contains("precision") || metadata.contains("crop") {
		return "crosshair"
	}

	if role == kAXSplitterRole as String {
		return "resize-ew"
	}

	let pressableRoles: Set<String> = [
		kAXButtonRole as String,
		axLinkRole,
		kAXMenuItemRole as String,
		kAXPopUpButtonRole as String,
		kAXRadioButtonRole as String,
		kAXCheckBoxRole as String,
		kAXTabGroupRole as String,
	]
	let hasPressAction = actions.contains(kAXPressAction as String)
	if enabled == false && (hasPressAction || pressableRoles.contains(role ?? "")) {
		return "not-allowed"
	}
	if hasPressAction || pressableRoles.contains(role ?? "") {
		return "pointer"
	}

	return nil
}

func currentSystemCursorType() -> String {
	let resolvedCursor: NSCursor? = DispatchQueue.main.sync {
		if #available(macOS 14.0, *) {
			return NSCursor.currentSystem ?? NSCursor.current
		}

		return NSCursor.current
	}

	guard let resolvedCursor else {
		return accessibilityCursorMatch() ?? "arrow"
	}

	guard let currentSignature = signature(for: resolvedCursor) else {
		return accessibilityCursorMatch() ?? "arrow"
	}

	guard let bestMatch = knownCursorSignatures.min(by: { lhs, rhs in
		signatureScore(currentSignature, lhs.1) < signatureScore(currentSignature, rhs.1)
	}) else {
		return accessibilityCursorMatch() ?? "arrow"
	}

	let bestScore = signatureScore(currentSignature, bestMatch.1)
	let primaryThreshold = strictSignatureAcceptanceThresholds[bestMatch.0] ?? signatureAcceptanceThreshold
	let matchedCursorType: String
	if bestScore > primaryThreshold {
		if let relaxedThreshold = relaxedSignatureAcceptanceThresholds[bestMatch.0], bestScore <= relaxedThreshold {
			matchedCursorType = bestMatch.0
		} else {
			matchedCursorType = "arrow"
		}
	} else {
		matchedCursorType = bestMatch.0
	}

	return matchedCursorType
}

func exportCursorImages() {
	let cursorForType: [(String, NSCursor)] = [
		("arrow", .arrow),
		("text", .iBeam),
		("pointer", .pointingHand),
		("crosshair", .crosshair),
		("open-hand", .openHand),
		("closed-hand", .closedHand),
		("resize-ew", .resizeLeftRight),
		("resize-ns", .resizeUpDown),
		("not-allowed", .operationNotAllowed),
	]

	for (name, cursor) in cursorForType {
		let image = cursor.image
		let hotspot = cursor.hotSpot
		let size = image.size
		guard size.width > 0, size.height > 0 else { continue }

		guard let tiffData = image.tiffRepresentation,
			  let bitmapRep = NSBitmapImageRep(data: tiffData),
			  let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
			continue
		}

		let base64 = pngData.base64EncodedString()
		let hotspotXRatio = hotspot.x / size.width
		let hotspotYRatio = hotspot.y / size.height
		let aspectRatio = size.width / size.height
		print("CURSOR_IMAGE:\(name):\(hotspotXRatio):\(hotspotYRatio):\(aspectRatio):\(base64)")
		fflush(stdout)
	}
}

if CommandLine.arguments.contains("--export-images") {
	exportCursorImages()
	exit(0)
}

// Report what TCC grants this helper process. The app's own
// isTrustedAccessibilityClient() check can pass while the helper is denied:
// when the app's code signature identifier does not match its bundle ID, TCC
// attributes the helper to the app's executable path instead of its bundle ID.
// CGEvent.tapCreate is not a usable signal here: a listen-only tap is created
// even when TCC denies it, and then simply never receives events.
if CommandLine.arguments.contains("--check-permissions") {
	let accessibilityTrusted = AXIsProcessTrusted()
	print("PERMISSION:accessibility:\(accessibilityTrusted ? 1 : 0)")
	print("PERMISSION:input-events:\(accessibilityTrusted || CGPreflightListenEventAccess() ? 1 : 0)")
	fflush(stdout)
	exit(0)
}

let caretMessagingTimeout: Float = 0.08
/// How long the camera keeps following after the last keystroke or caret move.
let typingHoldSeconds: TimeInterval = 1.0

/// Where a caret position came from, from most to least precise.
enum CaretSource: String {
	/// AXBoundsForRange: native text fields and text views.
	case textRange = "text-range"
	/// AXBoundsForTextMarkerRange: web content in WebKit, Chromium and Gecko.
	case textMarker = "text-marker"
	/// The focused text field's frame, for apps that expose the field but no caret.
	case element
	/// The last click in the focused app, for apps that expose nothing: users
	/// usually click a field before typing.
	case pointer
}

struct CaretLocation {
	let element: AXUIElement?
	let point: CGPoint
	let source: CaretSource
}

func frontmostApplication() -> NSRunningApplication? {
	if Thread.isMainThread {
		return NSWorkspace.shared.frontmostApplication
	}
	return DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
}

// Chromium and Electron only build their accessibility tree for assistive
// technology; AXManualAccessibility asks for it and other apps ignore it.
// Gecko (Firefox, Zen, ...) ignores that and only honours AXEnhancedUserInterface,
// which also changes window behaviour, so it is set for Gecko apps only and
// cleared again when the monitor stops.
let enhancedUserInterfaceLock = NSLock()
var enhancedUserInterfaceApps: [pid_t: AXUIElement] = [:]

func isGeckoApplication(_ app: NSRunningApplication) -> Bool {
	guard let bundleURL = app.bundleURL else { return false }
	return FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/MacOS/XUL").path)
}

func requestAccessibilityTree(_ app: NSRunningApplication, _ element: AXUIElement) {
	AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
	guard isGeckoApplication(app) else { return }
	enhancedUserInterfaceLock.lock()
	defer { enhancedUserInterfaceLock.unlock() }
	if enhancedUserInterfaceApps[app.processIdentifier] == nil,
		AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
		enhancedUserInterfaceApps[app.processIdentifier] = element
	}
}

func restoreEnhancedUserInterface() {
	enhancedUserInterfaceLock.lock()
	defer { enhancedUserInterfaceLock.unlock() }
	for element in enhancedUserInterfaceApps.values {
		AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
	}
	enhancedUserInterfaceApps.removeAll()
}

// Query the frontmost app rather than the system-wide element: a messaging
// timeout set on the system-wide element becomes the global timeout for every
// AX call in this process, including cursor-type detection.
var cachedCaretApplication: (pid: pid_t, bundleId: String, element: AXUIElement)?
func frontmostApplicationElement() -> (bundleId: String, element: AXUIElement)? {
	guard let app = frontmostApplication() else {
		cachedCaretApplication = nil
		return nil
	}
	let pid = app.processIdentifier
	if let cached = cachedCaretApplication, cached.pid == pid {
		return (cached.bundleId, cached.element)
	}
	let element = AXUIElementCreateApplication(pid)
	AXUIElementSetMessagingTimeout(element, caretMessagingTimeout)
	requestAccessibilityTree(app, element)
	let bundleId = app.bundleIdentifier ?? "pid-\(pid)"
	cachedCaretApplication = (pid, bundleId, element)
	return (bundleId, element)
}

func focusedElement(of app: AXUIElement) -> AXUIElement? {
	var focused: CFTypeRef?
	guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
		let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
	let element = focused as! AXUIElement
	AXUIElementSetMessagingTimeout(element, caretMessagingTimeout)
	return element
}

func isPlausibleCaretRect(_ rect: CGRect) -> Bool {
	return rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite
		&& rect.height.isFinite && rect.width >= 0 && rect.width <= 32
		&& rect.height > 0 && rect.height < 200
}

func rectValue(_ value: CFTypeRef?) -> CGRect? {
	guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
	var rect = CGRect.zero
	return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
}

// Only geometry is read here: never AXValue, the selected text or typed characters.
func textRangeCaretRect(_ element: AXUIElement) -> CGRect? {
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
		let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
	var range = CFRange()
	guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0,
		range.length == 0, let parameter = AXValueCreate(.cfRange, &range) else { return nil }
	var result: CFTypeRef?
	guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
		let rect = rectValue(result), isPlausibleCaretRect(rect) else { return nil }
	return rect
}

func textMarkerCaretRect(_ element: AXUIElement) -> CGRect? {
	var markerRange: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
		let markerRange else { return nil }
	var result: CFTypeRef?
	guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &result) == .success,
		let rect = rectValue(result), isPlausibleCaretRect(rect) else { return nil }
	return rect
}

func isTextInput(role: String, element: AXUIElement) -> Bool {
	return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
		|| attributeBool(element, axEditableAttribute) == true
}

func textInputFrame(_ element: AXUIElement) -> CGRect? {
	var positionValue: CFTypeRef?
	var sizeValue: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
		AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
		let positionValue, let sizeValue,
		CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
	var position = CGPoint.zero
	var size = CGSize.zero
	guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
		AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
		size.width > 0, size.height > 0,
		// A whole editor or web page is too big to say where the typing is.
		size.height < 400 else { return nil }
	return CGRect(origin: position, size: size)
}

/// The caret as reported by accessibility; nil when the app exposes nothing usable.
func accessibilityCaret(in app: AXUIElement) -> (location: CaretLocation?, role: String) {
	guard let element = focusedElement(of: app) else { return (nil, "no-focus") }
	let role = attributeString(element, kAXRoleAttribute) ?? "unknown"
	let subrole = attributeString(element, kAXSubroleAttribute) ?? ""
	// Secure inputs must not move the camera.
	if subrole.lowercased().contains("secure") { return (nil, "secure") }
	if let rect = textRangeCaretRect(element) {
		return (CaretLocation(element: element, point: CGPoint(x: rect.midX, y: rect.midY), source: .textRange), role)
	}
	if let rect = textMarkerCaretRect(element) {
		return (CaretLocation(element: element, point: CGPoint(x: rect.midX, y: rect.midY), source: .textMarker), role)
	}
	if isTextInput(role: role, element: element), let frame = textInputFrame(element) {
		return (CaretLocation(element: element, point: CGPoint(x: frame.midX, y: frame.midY), source: .element), role)
	}
	return (nil, role)
}

// A one-shot diagnostic for browser compatibility; it prints geometry only.
if let index = CommandLine.arguments.firstIndex(of: "--probe-caret") {
	var root = frontmostApplicationElement()?.element
	if CommandLine.arguments.count > index + 1,
		let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[index + 1]).first {
		root = AXUIElementCreateApplication(app.processIdentifier)
		AXUIElementSetMessagingTimeout(root!, caretMessagingTimeout)
		requestAccessibilityTree(app, root!)
		// Gecko builds its tree asynchronously after being asked for it.
		Thread.sleep(forTimeInterval: 0.5)
	}
	let result = root.map { accessibilityCaret(in: $0) }
	if let location = result?.location {
		print("CARET:\(location.point.x):\(location.point.y) source=\(location.source.rawValue) role=\(result!.role)")
	} else {
		print("CARET:none role=\(result?.role ?? "no-app") trusted=\(AXIsProcessTrusted())")
	}
	restoreEnhancedUserInterface()
	exit(0)
}

// Typing is detected from two independent signals so that it works in every
// app: keystrokes (from the event tap) and caret movement (from accessibility,
// which also catches paste and IME input). A click ends both.
let typingLock = NSLock()
var lastKeystrokeTime: TimeInterval = 0
var lastCaretMoveTime: TimeInterval = 0
var lastClickPoint: CGPoint?
/// App whose window received the last click; resolved lazily off the event tap.
var lastClickOwnerPid: pid_t?
var lastClickOwnerResolved = false

func markKeystroke() {
	typingLock.lock()
	lastKeystrokeTime = ProcessInfo.processInfo.systemUptime
	typingLock.unlock()
}

func markCaretMoved(_ moved: Bool) {
	typingLock.lock()
	lastCaretMoveTime = moved ? ProcessInfo.processInfo.systemUptime : 0
	typingLock.unlock()
}

func markClick(at point: CGPoint) {
	typingLock.lock()
	lastKeystrokeTime = 0
	lastCaretMoveTime = 0
	lastClickPoint = point
	lastClickOwnerPid = nil
	lastClickOwnerResolved = false
	typingLock.unlock()
}

// Keys pressed while one of these has focus drive the control (arrow keys in a
// list, space on a button), they are not typing, so no pointer fallback.
let nonTextFocusRoles: Set<String> = [
	"secure", "AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXList", "AXTable",
	"AXOutline", "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuButton", "AXPopUpButton",
	"AXSlider", "AXTabGroup", "AXImage", "AXDisclosureTriangle", "AXIncrementor",
]

/// The app owning the frontmost on-screen window under a point, e.g. the Dock
/// for a Dock click. Window bounds use the same top-left global coordinates as
/// CGEvent locations, and reading owner PIDs needs no screen recording access.
func windowOwnerPid(at point: CGPoint) -> pid_t? {
	guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
		as? [[String: Any]] else { return nil }
	for window in windows {
		guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
			let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
			bounds.contains(point),
			let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
		return ownerPid
	}
	return nil
}

/// The last click, but only if it landed in the app that has focus now. A click
/// on the Dock or in another app says nothing about where this app's text is.
func clickPointInFocusedApp(_ pid: pid_t?) -> CGPoint? {
	typingLock.lock()
	let point = lastClickPoint
	let resolved = lastClickOwnerResolved
	var ownerPid = lastClickOwnerPid
	typingLock.unlock()
	guard let point, let pid else { return nil }
	if !resolved {
		ownerPid = windowOwnerPid(at: point)
		typingLock.lock()
		if lastClickPoint == point {
			lastClickOwnerPid = ownerPid
			lastClickOwnerResolved = true
		}
		typingLock.unlock()
	}
	return ownerPid == pid ? point : nil
}

var previousCaret: CaretLocation?
/// The last caret read from a text range or marker, with the time it was read.
var lastPreciseCaret: (location: CaretLocation, time: TimeInterval)?
var lastCaretDebug = ""
func emitTextCaret() {
	let app = frontmostApplicationElement()
	let result = app.map { accessibilityCaret(in: $0.element) }
	var caret = result?.location
	let readTime = ProcessInfo.processInfo.systemUptime

	// A field can briefly report only its frame (e.g. while a popup opens) between
	// precise caret reads. Jumping to the frame's centre for one frame makes the
	// camera twitch, so keep the recent precise caret of that same field instead.
	if let current = caret, let element = current.element {
		if current.source == .element {
			if let precise = lastPreciseCaret, readTime - precise.time < typingHoldSeconds,
				let preciseElement = precise.location.element, CFEqual(preciseElement, element) {
				caret = precise.location
			}
		} else {
			lastPreciseCaret = (current, readTime)
		}
	}

	if let caret, caret.source != .element, let element = caret.element {
		if let previous = previousCaret, let previousElement = previous.element,
			CFEqual(previousElement, element) {
			if abs(caret.point.x - previous.point.x) > 0.2 || abs(caret.point.y - previous.point.y) > 0.2 {
				markCaretMoved(true)
			}
		} else {
			markCaretMoved(false)
		}
	} else {
		markCaretMoved(false)
	}
	previousCaret = caret

	// Resolve click ownership while the window under it is still the same.
	let clickPoint = clickPointInFocusedApp(cachedCaretApplication?.pid)
	typingLock.lock()
	let now = ProcessInfo.processInfo.systemUptime
	let isTyping = now - max(lastKeystrokeTime, lastCaretMoveTime) < typingHoldSeconds
	typingLock.unlock()

	// Without a caret or a click in this app the position is unknown; no zoom
	// is better than zooming somewhere unrelated.
	var location = caret
	if isTyping, location == nil, !nonTextFocusRoles.contains(result?.role ?? "") {
		location = clickPoint.map { CaretLocation(element: nil, point: $0, source: .pointer) }
	}

	// Log which caret source each app gives, once per change, so unsupported
	// apps can be diagnosed from a real recording. Roles only, never text.
	if isTyping {
		let debug = "\(app?.bundleId ?? "none"):\(result?.role ?? "none"):\(location?.source.rawValue ?? "none")"
		if debug != lastCaretDebug {
			lastCaretDebug = debug
			print("CARET_DEBUG:\(debug)")
		}
	}

	if isTyping, let location {
		print("CARET:\(location.point.x):\(location.point.y)")
	} else {
		print("CARET:none")
	}
	fflush(stdout)
}

var inputEventTap: CFMachPort?

func mouseInteractionCallback(
	proxy: CGEventTapProxy,
	type: CGEventType,
	event: CGEvent,
	refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
	let action: String
	let button: Int
	switch type {
	case .tapDisabledByTimeout, .tapDisabledByUserInput:
		// macOS disables a tap it considers slow; without this, clicks and
		// keystrokes silently stop for the rest of the recording.
		if let inputEventTap {
			CGEvent.tapEnable(tap: inputEventTap, enable: true)
		}
		return Unmanaged.passUnretained(event)
	case .keyDown:
		// Only the fact that a key was pressed is used, never which key.
		// Shortcuts do not count as typing.
		if !event.flags.contains(.maskCommand) && !event.flags.contains(.maskControl) {
			markKeystroke()
		}
		return Unmanaged.passUnretained(event)
	case .leftMouseDown:
		markClick(at: event.location)
		action = "mousedown"
		button = 1
	case .leftMouseUp:
		action = "mouseup"
		button = 1
	case .rightMouseDown:
		markClick(at: event.location)
		action = "mousedown"
		button = 2
	case .rightMouseUp:
		action = "mouseup"
		button = 2
	case .otherMouseDown:
		guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
			return Unmanaged.passUnretained(event)
		}
		action = "mousedown"
		button = 3
	case .otherMouseUp:
		guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
			return Unmanaged.passUnretained(event)
		}
		action = "mouseup"
		button = 3
	default:
		return Unmanaged.passUnretained(event)
	}

	print("INTERACTION:\(action):\(button)")
	fflush(stdout)
	return Unmanaged.passUnretained(event)
}

print("PERMISSION:accessibility:\(AXIsProcessTrusted() ? 1 : 0)")
fflush(stdout)

let mouseEventTypes: [CGEventType] = [
	.leftMouseDown,
	.leftMouseUp,
	.rightMouseDown,
	.rightMouseUp,
	.otherMouseDown,
	.otherMouseUp,
	.keyDown,
]
let mouseEventMask = mouseEventTypes.reduce(CGEventMask(0)) { mask, type in
	mask | (CGEventMask(1) << type.rawValue)
}
let mouseEventTap = CGEvent.tapCreate(
	tap: .cgSessionEventTap,
	place: .headInsertEventTap,
	options: .listenOnly,
	eventsOfInterest: mouseEventMask,
	callback: mouseInteractionCallback,
	userInfo: nil
)
if let mouseEventTap,
	let eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mouseEventTap, 0) {
	inputEventTap = mouseEventTap
	CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
	CGEvent.tapEnable(tap: mouseEventTap, enable: true)
} else {
	fputs("Mouse interaction event tap unavailable; click telemetry disabled\n", stderr)
	fflush(stderr)
	print("PERMISSION:input-events:0")
	fflush(stdout)
}

var lastState = ""
func emitStateIfNeeded() {
	let state = currentSystemCursorType()
	if state != lastState {
		lastState = state
		print("STATE:\(state)")
		fflush(stdout)
	}
}

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
timer.schedule(deadline: .now(), repeating: .milliseconds(50))
timer.setEventHandler {
	emitStateIfNeeded()
	emitTextCaret()
}
timer.resume()

// The app writes "stop" and then sends SIGTERM right away, so the flag set on
// Gecko apps has to be cleared on the signal too, not only on "stop".
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
terminationSource.setEventHandler {
	restoreEnhancedUserInterface()
	exit(0)
}
terminationSource.resume()

DispatchQueue.global(qos: .utility).async {
	while let line = readLine(strippingNewline: true)?.lowercased() {
		if line == "stop" {
			restoreEnhancedUserInterface()
			exit(0)
		}
	}
	restoreEnhancedUserInterface()
	exit(0)
}

RunLoop.main.run()
