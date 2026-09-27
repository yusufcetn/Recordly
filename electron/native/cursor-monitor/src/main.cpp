#include <windows.h>
#include <oleacc.h>
#include <UIAutomation.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdio>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

using Microsoft::WRL::ComPtr;

static std::atomic<bool> g_running{true};

static void stdinListener() {
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line == "stop") {
            g_running.store(false);
            return;
        }
    }
    g_running.store(false);
}

// ---------------------------------------------------------------------------
// Typing detection, mirroring electron/native/NativeCursorMonitor.swift.
//
// Typing is detected from two independent signals so that it works in every
// app: keystrokes (from a low-level keyboard hook) and caret movement (which
// also catches paste). A click ends both. Only the fact that a key was pressed
// is used, never which key, and no text content is ever read: every source
// below returns geometry only.
//
// Coordinates: this process is per-monitor DPI aware and prints physical screen
// pixels; electron/ipc/cursor/caret.ts converts them to DIPs.
// ---------------------------------------------------------------------------

constexpr ULONGLONG kTypingHoldMs = 1000;
// A whole editor or web page is too big to say where the typing is.
constexpr LONG kMaxFieldHeightPx = 400;

static std::atomic<ULONGLONG> g_lastKeystrokeMs{0};
static std::atomic<ULONGLONG> g_lastCaretMoveMs{0};
static std::atomic<unsigned> g_clickSequence{0};
static std::mutex g_clickMutex;
static bool g_hasClick = false;
static POINT g_lastClickPoint{};

static bool isKeyDown(int vk) {
    return (GetAsyncKeyState(vk) & 0x8000) != 0;
}

static LRESULT CALLBACK keyboardProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code == HC_ACTION && (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN)) {
        const auto* info = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lParam);
        const DWORD vk = info->vkCode;
        const bool isModifier = vk == VK_SHIFT || vk == VK_LSHIFT || vk == VK_RSHIFT ||
            vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL || vk == VK_MENU ||
            vk == VK_LMENU || vk == VK_RMENU || vk == VK_LWIN || vk == VK_RWIN || vk == VK_CAPITAL;
        const bool ctrl = isKeyDown(VK_CONTROL);
        const bool alt = (info->flags & LLKHF_ALTDOWN) != 0 || isKeyDown(VK_MENU);
        // AltGr is Ctrl+Alt and types characters such as @ on Turkish and German layouts.
        const bool altGr = ctrl && alt;
        const bool shortcut = isKeyDown(VK_LWIN) || isKeyDown(VK_RWIN) || ((ctrl || alt) && !altGr);
        if (!isModifier && !shortcut) {
            g_lastKeystrokeMs.store(GetTickCount64());
        }
    }
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

static LRESULT CALLBACK mouseProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code == HC_ACTION && (wParam == WM_LBUTTONDOWN || wParam == WM_RBUTTONDOWN)) {
        const auto* info = reinterpret_cast<const MSLLHOOKSTRUCT*>(lParam);
        {
            std::lock_guard<std::mutex> lock(g_clickMutex);
            g_hasClick = true;
            g_lastClickPoint = info->pt;
        }
        g_lastKeystrokeMs.store(0);
        g_lastCaretMoveMs.store(0);
        // The window under the click is resolved later on the main thread: hit
        // testing can message other processes, which must never happen inside a
        // low-level hook (Windows silently removes hooks that time out).
        g_clickSequence.fetch_add(1);
    }
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

static void inputHookThread() {
    HINSTANCE module = GetModuleHandleW(nullptr);
    HHOOK keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardProc, module, 0);
    HHOOK mouseHook = SetWindowsHookExW(WH_MOUSE_LL, mouseProc, module, 0);
    if (!keyboardHook || !mouseHook) {
        std::cerr << "Input hooks unavailable; typing detection limited to caret movement" << std::endl;
    }
    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    }
    if (keyboardHook) UnhookWindowsHookEx(keyboardHook);
    if (mouseHook) UnhookWindowsHookEx(mouseHook);
}

static bool isPlausibleCaretSize(LONG width, LONG height) {
    return height > 0 && height < 200 && width >= 0 && width <= 32;
}

// Client coordinates of a DPI-unaware or system-aware window are logical; this
// process works in physical pixels.
static bool clientToPhysicalScreen(HWND hwnd, POINT& point) {
    DPI_AWARENESS_CONTEXT windowContext = GetWindowDpiAwarenessContext(hwnd);
    DPI_AWARENESS_CONTEXT previousContext = SetThreadDpiAwarenessContext(windowContext);
    const BOOL converted = ClientToScreen(hwnd, &point);
    if (previousContext) SetThreadDpiAwarenessContext(previousContext);
    if (!converted) return false;
    if (GetAwarenessFromDpiAwarenessContext(windowContext) != DPI_AWARENESS_PER_MONITOR_AWARE) {
        LogicalToPhysicalPointForPerMonitorDPI(hwnd, &point);
    }
    return true;
}

// Classic Win32 text boxes (and apps that keep the system caret in sync).
static bool readWin32Caret(const GUITHREADINFO& gui, POINT& out) {
    if (!gui.hwndCaret) return false;
    const RECT& rect = gui.rcCaret;
    if (!isPlausibleCaretSize(rect.right - rect.left, rect.bottom - rect.top)) return false;
    POINT point{(rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2};
    if (!clientToPhysicalScreen(gui.hwndCaret, point)) return false;
    out = point;
    return true;
}

// The caret object screen magnifiers use; Chromium (Chrome, Edge, Electron) and
// Firefox expose it even though they draw their own caret.
static bool readMsaaCaret(HWND hwnd, POINT& out) {
    if (!hwnd) return false;
    ComPtr<IAccessible> caret;
    if (FAILED(AccessibleObjectFromWindow(hwnd, static_cast<DWORD>(OBJID_CARET), __uuidof(IAccessible),
            reinterpret_cast<void**>(caret.GetAddressOf()))) || !caret) {
        return false;
    }
    VARIANT self;
    VariantInit(&self);
    self.vt = VT_I4;
    self.lVal = CHILDID_SELF;
    long left = 0, top = 0, width = 0, height = 0;
    if (FAILED(caret->accLocation(&left, &top, &width, &height, self))) return false;
    if (!isPlausibleCaretSize(width, height) || (left == 0 && top == 0)) return false;
    out = POINT{left + width / 2, top + height / 2};
    return true;
}

static ComPtr<IUIAutomation> g_automation;

static void initUiAutomation() {
    if (FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&g_automation)))) {
        g_automation.Reset();
        return;
    }
    // A hung provider must not stall the 50 ms loop for long.
    ComPtr<IUIAutomation2> automation2;
    if (SUCCEEDED(g_automation.As(&automation2))) {
        automation2->put_ConnectionTimeout(200);
        automation2->put_TransactionTimeout(200);
    }
}

struct FocusInfo {
    ComPtr<IUIAutomationElement> element;
    CONTROLTYPEID controlType = 0;
    bool isPassword = false;
};

static FocusInfo readFocus() {
    FocusInfo info;
    if (!g_automation || FAILED(g_automation->GetFocusedElement(&info.element)) || !info.element) {
        info.element.Reset();
        return info;
    }
    info.element->get_CurrentControlType(&info.controlType);
    BOOL isPassword = FALSE;
    if (SUCCEEDED(info.element->get_CurrentIsPassword(&isPassword))) {
        info.isPassword = isPassword != FALSE;
    }
    return info;
}

static bool pointFromRange(IUIAutomationTextRange* range, bool useLastRect, bool leftEdge, POINT& out) {
    SAFEARRAY* rects = nullptr;
    if (FAILED(range->GetBoundingRectangles(&rects)) || !rects) return false;
    bool found = false;
    LONG lower = 0, upper = -1;
    SafeArrayGetLBound(rects, 1, &lower);
    SafeArrayGetUBound(rects, 1, &upper);
    const LONG rectCount = (upper - lower + 1) / 4;
    double* values = nullptr;
    if (rectCount > 0 && SUCCEEDED(SafeArrayAccessData(rects, reinterpret_cast<void**>(&values)))) {
        const double* rect = values + (useLastRect ? (rectCount - 1) * 4 : 0);
        const double left = rect[0], top = rect[1], width = rect[2], height = rect[3];
        if (height > 0 && height < 200) {
            out = POINT{static_cast<LONG>(leftEdge ? left : left + width), static_cast<LONG>(top + height / 2)};
            found = true;
        }
        SafeArrayUnaccessData(rects);
    }
    SafeArrayDestroy(rects);
    return found;
}

// UI Automation caret: WinUI/UWP, WPF and modern Win32 apps.
static bool readUiaCaret(IUIAutomationElement* element, POINT& out) {
    ComPtr<IUIAutomationTextPattern2> pattern;
    if (FAILED(element->GetCurrentPatternAs(UIA_TextPattern2Id, IID_PPV_ARGS(&pattern))) || !pattern) {
        return false;
    }
    BOOL isActive = FALSE;
    ComPtr<IUIAutomationTextRange> caret;
    if (FAILED(pattern->GetCaretRange(&isActive, &caret)) || !caret) return false;
    if (pointFromRange(caret.Get(), false, true, out)) return true;
    // A collapsed range often has no rectangle: use the next character's left
    // edge, or at the end of the text the previous character's right edge.
    int moved = 0;
    ComPtr<IUIAutomationTextRange> next;
    if (SUCCEEDED(caret->Clone(&next)) &&
        SUCCEEDED(next->MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, 1, &moved)) &&
        moved == 1 && pointFromRange(next.Get(), false, true, out)) {
        return true;
    }
    ComPtr<IUIAutomationTextRange> previous;
    if (SUCCEEDED(caret->Clone(&previous)) &&
        SUCCEEDED(previous->MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -1, &moved)) &&
        moved == -1 && pointFromRange(previous.Get(), true, false, out)) {
        return true;
    }
    return false;
}

// The focused field's centre, for apps that expose the field but no caret.
static bool readUiaFieldCenter(const FocusInfo& focus, POINT& out) {
    if (focus.controlType != UIA_EditControlTypeId && focus.controlType != UIA_ComboBoxControlTypeId &&
        focus.controlType != UIA_DocumentControlTypeId) {
        return false;
    }
    RECT rect{};
    if (FAILED(focus.element->get_CurrentBoundingRectangle(&rect))) return false;
    const LONG width = rect.right - rect.left, height = rect.bottom - rect.top;
    if (width <= 0 || height <= 0 || height >= kMaxFieldHeightPx) return false;
    out = POINT{rect.left + width / 2, rect.top + height / 2};
    return true;
}

// Keys pressed while one of these has focus drive the control (arrow keys in a
// list, space on a button); they are not typing, so no click fallback.
static bool isNonTextControl(CONTROLTYPEID type) {
    switch (type) {
    case UIA_ButtonControlTypeId:
    case UIA_CheckBoxControlTypeId:
    case UIA_RadioButtonControlTypeId:
    case UIA_HyperlinkControlTypeId:
    case UIA_ListControlTypeId:
    case UIA_ListItemControlTypeId:
    case UIA_TreeControlTypeId:
    case UIA_TreeItemControlTypeId:
    case UIA_MenuControlTypeId:
    case UIA_MenuBarControlTypeId:
    case UIA_MenuItemControlTypeId:
    case UIA_SliderControlTypeId:
    case UIA_TabControlTypeId:
    case UIA_TabItemControlTypeId:
    case UIA_ImageControlTypeId:
    case UIA_TableControlTypeId:
    case UIA_DataGridControlTypeId:
    case UIA_DataItemControlTypeId:
    case UIA_SplitButtonControlTypeId:
    case UIA_ScrollBarControlTypeId:
        return true;
    default:
        return false;
    }
}

static std::string controlTypeName(CONTROLTYPEID type) {
    switch (type) {
    case 0: return "no-focus";
    case UIA_EditControlTypeId: return "Edit";
    case UIA_DocumentControlTypeId: return "Document";
    case UIA_ComboBoxControlTypeId: return "ComboBox";
    case UIA_PaneControlTypeId: return "Pane";
    case UIA_WindowControlTypeId: return "Window";
    case UIA_GroupControlTypeId: return "Group";
    case UIA_CustomControlTypeId: return "Custom";
    default: return "ct-" + std::to_string(type);
    }
}

static bool isWin32PasswordEdit(HWND hwnd) {
    if (!hwnd) return false;
    wchar_t className[16] = {};
    GetClassNameW(hwnd, className, 16);
    return _wcsicmp(className, L"Edit") == 0 && (GetWindowLongW(hwnd, GWL_STYLE) & ES_PASSWORD) != 0;
}

static std::string processName(DWORD pid) {
    static std::unordered_map<DWORD, std::string> cache;
    if (auto found = cache.find(pid); found != cache.end()) return found->second;
    std::string name = "pid-" + std::to_string(pid);
    if (HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
        wchar_t path[MAX_PATH] = {};
        DWORD size = MAX_PATH;
        if (QueryFullProcessImageNameW(process, 0, path, &size)) {
            std::wstring fullPath(path, size);
            std::wstring baseName = fullPath.substr(fullPath.find_last_of(L"\\/") + 1);
            const int bytes = WideCharToMultiByte(CP_UTF8, 0, baseName.c_str(), -1, nullptr, 0, nullptr, nullptr);
            if (bytes > 1) {
                std::string utf8(static_cast<size_t>(bytes - 1), '\0');
                WideCharToMultiByte(CP_UTF8, 0, baseName.c_str(), -1, utf8.data(), bytes, nullptr, nullptr);
                name = utf8;
            }
        }
        CloseHandle(process);
    }
    cache[pid] = name;
    return name;
}

struct CaretReading {
    bool found = false;
    POINT point{};
    std::string source = "none";
    HWND field = nullptr;
};

struct TypingTracker {
    CaretReading previous;
    unsigned seenClickSequence = 0;
    bool hasPrecise = false;
    CaretReading lastPrecise;
    ULONGLONG lastPreciseMs = 0;
    bool clickOwnerResolved = false;
    DWORD clickOwnerPid = 0;
    std::string lastDebug;
};

static std::string emitTextCaret(TypingTracker& tracker) {
    const ULONGLONG now = GetTickCount64();
    HWND foreground = GetForegroundWindow();
    DWORD foregroundPid = 0;
    const DWORD foregroundThread = foreground ? GetWindowThreadProcessId(foreground, &foregroundPid) : 0;
    GUITHREADINFO gui{};
    gui.cbSize = sizeof(gui);
    const bool haveGui = foregroundThread != 0 && GetGUIThreadInfo(foregroundThread, &gui);
    HWND field = haveGui && gui.hwndFocus ? gui.hwndFocus : foreground;

    const FocusInfo focus = readFocus();
    const bool secure = focus.isPassword || isWin32PasswordEdit(field);
    const std::string role = secure ? "secure" : controlTypeName(focus.controlType);

    CaretReading reading;
    reading.field = field;
    POINT point{};
    if (!secure) {
        if (haveGui && readWin32Caret(gui, point)) {
            reading = {true, point, "win32-caret", field};
        } else if (readMsaaCaret(field, point)) {
            reading = {true, point, "msaa-caret", field};
        } else if (focus.element && readUiaCaret(focus.element.Get(), point)) {
            reading = {true, point, "uia-caret", field};
        } else if (focus.element && readUiaFieldCenter(focus, point)) {
            reading = {true, point, "element", field};
        }
    }

    // A field can briefly report only its frame between precise caret reads;
    // keep the recent precise caret of that same field instead of jumping.
    if (reading.found && reading.source == "element") {
        if (tracker.hasPrecise && tracker.lastPrecise.field == field && now - tracker.lastPreciseMs < kTypingHoldMs) {
            reading = tracker.lastPrecise;
        }
    } else if (reading.found) {
        tracker.hasPrecise = true;
        tracker.lastPrecise = reading;
        tracker.lastPreciseMs = now;
    }

    // A click can move the caret to another field inside the same window (web
    // pages share one window), which is not typing: do not compare across it.
    const unsigned clickSequence = g_clickSequence.load();
    if (clickSequence != tracker.seenClickSequence) {
        tracker.seenClickSequence = clickSequence;
        tracker.previous = CaretReading{};
        tracker.clickOwnerResolved = false;
    }

    if (reading.found && reading.source != "element") {
        if (tracker.previous.found && tracker.previous.field == reading.field) {
            if (tracker.previous.point.x != reading.point.x || tracker.previous.point.y != reading.point.y) {
                g_lastCaretMoveMs.store(now);
            }
        } else {
            g_lastCaretMoveMs.store(0);
        }
    } else {
        g_lastCaretMoveMs.store(0);
    }
    tracker.previous = reading;

    const ULONGLONG lastKeystroke = g_lastKeystrokeMs.load();
    const ULONGLONG lastCaretMove = g_lastCaretMoveMs.load();
    const ULONGLONG lastTyping = lastKeystroke > lastCaretMove ? lastKeystroke : lastCaretMove;
    const bool isTyping = lastTyping != 0 && now - lastTyping < kTypingHoldMs;

    // The last click, but only if it landed in the app that has focus now: a
    // click on the taskbar or another app says nothing about where this app's
    // text is. Without a caret or such a click, no zoom beats a wrong zoom.
    if (isTyping && !reading.found && !secure && !isNonTextControl(focus.controlType)) {
        bool hasClick = false;
        POINT clickPoint{};
        {
            std::lock_guard<std::mutex> lock(g_clickMutex);
            hasClick = g_hasClick;
            clickPoint = g_lastClickPoint;
        }
        if (hasClick && !tracker.clickOwnerResolved) {
            tracker.clickOwnerPid = 0;
            if (HWND clicked = WindowFromPoint(clickPoint)) {
                GetWindowThreadProcessId(GetAncestor(clicked, GA_ROOT), &tracker.clickOwnerPid);
            }
            tracker.clickOwnerResolved = true;
        }
        if (hasClick && tracker.clickOwnerPid != 0 && tracker.clickOwnerPid == foregroundPid) {
            reading = {true, clickPoint, "pointer", field};
        }
    }

    std::string output;
    // Which caret source each app provides, once per change, so unsupported
    // apps can be diagnosed from a real recording. Names and roles only.
    if (isTyping) {
        const std::string debug = processName(foregroundPid) + ":" + role + ":" + (reading.found ? reading.source : "none");
        if (debug != tracker.lastDebug) {
            tracker.lastDebug = debug;
            output += "CARET_DEBUG:" + debug + "\n";
        }
    }
    if (isTyping && reading.found) {
        output += "CARET:" + std::to_string(reading.point.x) + ":" + std::to_string(reading.point.y) + "\n";
    } else {
        output += "CARET:none\n";
    }
    return output;
}

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const HRESULT comResult = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    initUiAutomation();

    std::unordered_map<HCURSOR, std::string> cursorMap;
    cursorMap[LoadCursor(NULL, IDC_ARROW)]    = "arrow";
    cursorMap[LoadCursor(NULL, IDC_IBEAM)]    = "text";
    cursorMap[LoadCursor(NULL, IDC_HAND)]     = "pointer";
    cursorMap[LoadCursor(NULL, IDC_CROSS)]    = "crosshair";
    cursorMap[LoadCursor(NULL, IDC_NO)]       = "not-allowed";
    cursorMap[LoadCursor(NULL, IDC_SIZEWE)]   = "resize-ew";
    cursorMap[LoadCursor(NULL, IDC_SIZENS)]   = "resize-ns";
    cursorMap[LoadCursor(NULL, IDC_SIZEALL)]  = "open-hand";
    cursorMap[LoadCursor(NULL, IDC_WAIT)]     = "arrow";
    cursorMap[LoadCursor(NULL, IDC_APPSTARTING)] = "arrow";

    std::thread listener(stdinListener);
    listener.detach();
    std::thread hooks(inputHookThread);
    hooks.detach();

    std::string lastType;
    TypingTracker tracker;

    while (g_running.load()) {
        CURSORINFO ci = {};
        ci.cbSize = sizeof(ci);

        if (GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING)) {
            auto it = cursorMap.find(ci.hCursor);
            std::string type = (it != cursorMap.end()) ? it->second : "arrow";

            if (type != lastType) {
                lastType = type;
                std::cout << "STATE:" << type << std::endl;
            }
        }

        std::cout << emitTextCaret(tracker) << std::flush;

        Sleep(50);
    }

    g_automation.Reset();
    if (SUCCEEDED(comResult)) CoUninitialize();
    return 0;
}
