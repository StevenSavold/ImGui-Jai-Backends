// This file is an attempt to be a faithful recreation of the original imgui 
// backend file(https://github.com/ocornut/imgui/blob/master/backends/imgui_impl_win32.cpp)
// in Jai. It is mostly syntax changes, but there are a few things that needed to be 
// changed to fit the Jai way of doing things.
//
// This file assumes that you have imported Jai's Gamepad module and called init_gamepad() 
// and update_gamepad() at the appropriate times in your application code as dictated by 
// that module. It might be better for us not to depend on that module and we might make 
// that change in the future, but for now this is needed.
//

ImGui_ImplWin32_Data :: struct {
    hWnd: HWND;
    MouseHwnd: HWND;
    MouseTrackedArea: s32; // 0: not tracked, 1: client area, 2: non-client area
    MouseButtonsDown: s32;
    Time: s64;
    TicksPerSecond: s64;
    LastMouseCursor: ImGui.MouseCursor;
    WantUpdateMonitors: bool;

    HasGamepad: bool;
    WantUpdateHasGamepad: bool;
    // NOTE(Steven): Removed because Jai's Gamepad module brings these in for us
    // XInputDLL: HMODULE;
    // XInputGetCapabilities: PFN_XInputGetCapabilities;
    // XInputGetState: PFN_XInputGetState;
}

ImGui_ImplWin32_Init :: (hwnd: *void) -> bool {
    return ImGui_ImplWin32_InitEx(hwnd, false);
}

ImGui_ImplWin32_InitForOpenGL :: (hwnd: *void) -> bool {
    // OpenGL needs CS_OWNDC
    return ImGui_ImplWin32_InitEx(hwnd, true);
}

ImGui_ImplWin32_Shutdown :: () {
    bd := ImGui_ImplWin32_GetBackendData();
    assert(bd != null, "No platform backend to shutdown, or already shutdown?");
    io := ImGui.GetIO();

    ImGui_ImplWin32_ShutdownPlatformInterface();

    // Unload XInput library
    // NOTE(Steven): Removed because we never loaded this ourselves.

    io.BackendPlatformName = null;
    io.BackendPlatformUserData = null;
    io.BackendFlags_ &= ~(.HasMouseCursors | .HasSetMousePos | .HasGamepad | .PlatformHasViewports | .HasMouseHoveredViewport);
    free(bd);
}

ImGui_ImplWin32_NewFrame :: () {
    io := ImGui.GetIO();
    bd := ImGui_ImplWin32_GetBackendData();
    assert(bd != null, "Did you call ImGui_ImplWin32_Init()?");

    // Setup display size (every frame to accomodate for window resizing)
    rect: RECT;
    GetClientRect(bd.hWnd, *rect);
    io.DisplaySize = ImGui.ImVec2.{ cast(float)(rect.right - rect.left), cast(float)(rect.bottom - rect.top) };
    if bd.WantUpdateMonitors
        ImGui_ImplWin32_UpdateMonitors();

    // Setup time step
    current_time: s64;
    QueryPerformanceCounter(*current_time);
    io.DeltaTime = cast(float)(current_time - bd.Time) / bd.TicksPerSecond;
    bd.Time = current_time;

    // Update OS mouse positon
    ImGui_ImplWin32_UpdateMouseData();

    // Process workarounds for the know Windows key handling issues
    ImGui_ImplWin32_ProcessKeyEventsWorkarounds();

    // Update OS mouse cursor wit he cursor requested by imgui
    mouse_cursor := ifx io.MouseDrawCursor then .ImGuiMouseCursor_None else ImGui.GetMouseCursor();
    if bd.LastMouseCursor != mouse_cursor {
        bd.LastMouseCursor = mouse_cursor;
        ImGui_ImplWin32_UpdateMouseCursor();
    }

    // Update game controllers (if enabled and available)
    ImGui_ImplWin32_UpdateGamepads();
}

ImGui_ImplWin32_WindowProc :: (hwnd: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> s64 #c_call {
    new_context: Context;
    new_context.allocator = Context.default_allocator;
    new_context.logger    = Context.default_logger;

    push_context new_context {

        if ImGui.GetCurrentContext() == null
            return 0;
        
        io := ImGui.GetIO();
        bd := ImGui_ImplWin32_GetBackendData();

        if message == {
            case WM_MOUSEMOVE;   #through;
            case WM_NCMOUSEMOVE;
                // We need to call TrackMouseEvent in order to receive WM_MOUSELEAVE events
                mouse_source := GetMouseSourceFromMessageExtraInfo();
                area : s32 = ifx message == WM_MOUSEMOVE then cast(s32)1 else cast(s32)2;
                bd.MouseHwnd = hwnd;
                if bd.MouseTrackedArea != area {
                    tme_cancel := TRACKMOUSEEVENT.{ size_of(TRACKMOUSEEVENT), TME_CANCEL, hwnd, 0 };
                    tme_track := TRACKMOUSEEVENT.{ size_of(TRACKMOUSEEVENT), cast(DWORD)(ifx area == 2 then (TME_LEAVE | TME_NONCLIENT) else TME_LEAVE), hwnd, 0 };
                    if bd.MouseTrackedArea != 0
                        TrackMouseEvent(*tme_cancel);
                    TrackMouseEvent(*tme_track);
                    bd.MouseTrackedArea = area;
                }
                mouse_pos := POINT.{ xx LOWORD(lParam), xx HIWORD(lParam) };
                want_absolute_pos := (io.ConfigFlags_ & .ImGuiConfigFlags_ViewportsEnable) != 0;
                if message == WM_MOUSEMOVE && want_absolute_pos // WM_MOUSEMOVE are client-relative coordinates.
                    ClientToScreen(hwnd, *mouse_pos);
                if message == WM_NCMOUSEMOVE && !want_absolute_pos // WMNCMOUSEMOVE are absolute coordinates.
                    ScreenToClient(hwnd, *mouse_pos);
                io.AddMouseSourceEvent(io, mouse_source);
                io.AddMousePosEvent(io, cast(float)mouse_pos.x, cast(float)mouse_pos.y);

            case WM_MOUSELEAVE; #through;
            case WM_NCMOUSELEAVE;
                area := ifx message == WM_MOUSELEAVE then 1 else 2;
                if bd.MouseTrackedArea == area {
                    if bd.MouseHwnd == hwnd
                        bd.MouseHwnd == null;
                    bd.MouseTrackedArea = 0;
                    io.AddMousePosEvent(io, -FLOAT32_MAX, -FLOAT32_MAX);
                }
            
            case WM_LBUTTONDOWN;   #through;
            case WM_RBUTTONDOWN;   #through;
            case WM_MBUTTONDOWN;   #through;
            case WM_XBUTTONDOWN;   #through;
            case WM_LBUTTONDBLCLK; #through;
            case WM_RBUTTONDBLCLK; #through;
            case WM_MBUTTONDBLCLK; #through;
            case WM_XBUTTONDBLCLK;
                mouse_source := GetMouseSourceFromMessageExtraInfo();
                button: s32 = 0;
                if message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK button = 0;
                if message == WM_RBUTTONDOWN || message == WM_RBUTTONDBLCLK button = 1;
                if message == WM_MBUTTONDOWN || message == WM_MBUTTONDBLCLK button = 2;
                if message == WM_XBUTTONDOWN || message == WM_XBUTTONDBLCLK button = ifx HIWORD(xx wParam) == XBUTTON1 then cast(s32)3 else cast(s32)4;
                if bd.MouseButtonsDown == 0 && GetCapture() == null
                    SetCapture(hwnd);

                bd.MouseButtonsDown |= cast(s32)1 << button;
                io.AddMouseSourceEvent(io, mouse_source);
                io.AddMouseButtonEvent(io, button, true);
                return 0;

            case WM_LBUTTONUP; #through;
            case WM_RBUTTONUP; #through;
            case WM_MBUTTONUP; #through;
            case WM_XBUTTONUP;
                mouse_source := GetMouseSourceFromMessageExtraInfo();
                button: s32 = 0;
                if message == WM_LBUTTONUP then button = 0;
                if message == WM_RBUTTONUP then button = 1;
                if message == WM_MBUTTONUP then button = 2;
                if message == WM_XBUTTONUP then button = ifx HIWORD(xx wParam) == XBUTTON1 then cast(s32)3 else cast(s32)4;
                bd.MouseButtonsDown &= ~(cast(s32)1 << button);
                if bd.MouseButtonsDown == 0 && GetCapture() == hwnd
                    ReleaseCapture();

                io.AddMouseSourceEvent(io, mouse_source);
                io.AddMouseButtonEvent(io, button, false);
                return 0;
            
            case WM_MOUSEWHEEL;
                io.AddMouseWheelEvent(io, 0.0, cast(float)HIWORD(xx wParam) / cast(float)WHEEL_DELTA);
                return 0;

            case WM_MOUSEHWHEEL;
                io.AddMouseWheelEvent(io, (-cast(float)HIWORD(xx wParam)) / cast(float)WHEEL_DELTA, 0.0);
                return 0;

            case WM_KEYDOWN;    #through;
            case WM_KEYUP;      #through;
            case WM_SYSKEYDOWN; #through;
            case WM_SYSKEYUP;
                is_key_down := (message == WM_KEYDOWN || message == WM_SYSKEYDOWN);
                if wParam < 256 {
                    // Submit modifiers
                    ImGui_ImplWin32_UpdateKeyModifiers();

                    // Obtain virtual key code
                    // (keypad enter doesn't have its own... VK_RETURN with KF_EXTENDED flag means keypad enter, see IM_VK_KEYPAD_ENTER definition for details, it is mapped to ImGuiKey_KeyPadEnter.)
                    vk := cast(s32)wParam;
                    if (wParam == VK_RETURN) && (HIWORD(lParam) & KF_EXTENDED)
                        vk = IM_VK_KEYPAD_ENTER;

                    // Submit key event
                    key := ImGui_ImplWin32_VirtualKeyToImGuiKey(xx vk);
                    scancode := cast(s32)LOBYTE(HIWORD(lParam));
                    if key != .ImGuiKey_None
                        ImGui_ImplWin32_AddKeyEvent(key, is_key_down, vk, scancode);
                    
                    // Submit individual left/right modifier events
                    if vk == VK_SHIFT {
                        // Important: Shift keys tend to get stuck when pressed together, missing key-up events are corrected in ImGui_ImplWin32_ProcessKeyEventsWorkarounds()
                        if IsVkDown(VK_LSHIFT) == is_key_down then ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_LeftShift, is_key_down, VK_LSHIFT, scancode);
                        if IsVkDown(VK_RSHIFT) == is_key_down then ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_RightShift, is_key_down, VK_RSHIFT, scancode);
                    }
                    else if vk == VK_CONTROL {
                        if IsVkDown(VK_LCONTROL) == is_key_down then ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_LeftCtrl, is_key_down, VK_LCONTROL, scancode);
                        if IsVkDown(VK_RCONTROL) == is_key_down then ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_RightCtrl, is_key_down, VK_RCONTROL, scancode);
                    }
                    else if vk == VK_MENU {
                        if IsVkDown(VK_LMENU) == is_key_down then ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_LeftAlt, is_key_down, VK_LMENU, scancode);
                        if IsVkDown(VK_RMENU) == is_key_down then ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_RightAlt, is_key_down, VK_RMENU, scancode);
                    }
                }
                return 0;

            case WM_SETFOCUS;  #through;
            case WM_KILLFOCUS;
                io.AddFocusEvent(io, message == WM_SETFOCUS);
                return 0;
            
            case WM_CHAR;
                if IsWindowUnicode(hwnd) {
                    // You can also use ToAscii()+GetKeyboardState() to retrieve characters.
                    if wParam > 0 && wParam < 0x10000 {
                        io.AddInputCharacterUTF16(io, cast(u16)wParam);
                    }
                }
                else {
                    wch : u16 = 0;
                    MultiByteToWideChar(CP_ACP, MB_PRECOMPOSED, cast(*u8)*wParam, 1, *wch, 1);
                    io.AddInputCharacter(io, wch);
                }
                return 0;

            case WM_SETCURSOR;
                // This is required to restore cursor when transitioning from e.g resize borders to client area
                if LOWORD(lParam) == HTCLIENT && ImGui_ImplWin32_UpdateMouseCursor()
                    return 1;
                return 0;

            case WM_DEVICECHANGE;
                if wParam == DBT_DEVNODES_CHANGED
                    bd.WantUpdateHasGamepad = true;
                return 0;
            
            case WM_DISPLAYCHANGE;
                bd.WantUpdateMonitors = true;
                return 0;
        }

        return 0;
    }
}

//
// DPI Functions
//
// Helper function to enable DPI awareness without setting up a manifest
ImGui_ImplWin32_EnableDpiAwareness :: () {
    // Make sure monitors will be updated with latest correct scaling
    bd := ImGui_ImplWin32_GetBackendData();
    if bd
        bd.WantUpdateMonitors = true;
    
    if _IsWindows10OrGreater() {
        if !user32_dll
            user32_dll = LoadLibraryA("user32.dll"); // Reference counted per-process
        SetThreadDpiAwarenessContext : (dpiContext: DPI_AWARENESS_CONTEXT) -> DPI_AWARENESS_CONTEXT #foreign = xx GetProcAddress(user32_dll, "SetThreadDpiAwarenessContext");

        if SetThreadDpiAwarenessContext {
            SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            return;
        }
    }
    if _IsWindows8Point1OrGreater() {
        if !shcore_dll
            shcore_dll = LoadLibraryA("shcore.dll"); // Reference counted per-process
        SetProcessDpiAwareness : (dpiContext: PROCESS_DPI_AWARENESS) -> HRESULT #foreign = xx GetProcAddress(shcore_dll, "SetProcessDpiAwareness");
        if SetProcessDpiAwareness {
            SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE);
            return;
        }
    }

    // NOTE(Steven): This really should only be for _WIN32_WINNT >= 0x0600
    SetProcessDPIAware();
}

ImGui_ImplWin32_GetDpiScaleForMonitor :: (monitor: *void) -> float {
    xdpi: u32 = 96;
    ydpi: u32 = 96;

    if _IsWindows8Point1OrGreater() {
        if !shcore_dll
            shcore_dll = LoadLibraryA("shcore.dll"); // Reference counted per-process
        GetDpiForMonitor: (monitor: HMONITOR, dpiType: MONITOR_DPI_TYPE, dpiX: *u32, dpiY: *u32) -> HRESULT #foreign = xx GetProcAddress(shcore_dll, "GetDpiForMonitor");
        if GetDpiForMonitor {
            GetDpiForMonitor(cast(HMONITOR)monitor, MDT_EFFECTIVE_DPI, *xdpi, *ydpi);
            assert(xdpi == ydpi, "Please contact me if you hit this assert!");
            return xdpi / 96.0;
        }
    }

    dc := GetDC(null);
    xdpi = xx GetDeviceCaps(dc, LOGPIXELSX);
    ydpi = xx GetDeviceCaps(dc, LOGPIXELSY);
    assert(xdpi == ydpi, "Please contact me if you hit this assert!");
    ReleaseDC(null, dc);

    return xdpi / 96.0;
}

ImGui_ImplWin32_GetDpiScaleForHwnd :: (hwnd: *void) -> float {
    monitor := MonitorFromWindow(cast(HWND)hwnd, MONITOR_DEFAULTTONEAREST);
    return ImGui_ImplWin32_GetDpiScaleForMonitor(monitor);
}

//
// Transperency related helpers (optional)
//
// [experimental]
// Borrowed from GLFW's function updateFramebufferTransparency() in src/win32_window.c
// (the Dwm* functions are Vista era functions but we are borrowing logic from GLFW)
ImGui_ImplWin32_EnableAlphaCompositing :: (hwnd: *void) {
    if !_IsWindowsVistaOrGreater()
        return;

    composition: BOOL;
    if FAILED(DwmIsCompositionEnabled(*composition)) || !composition
        return;

    opaque: BOOL;
    color: DWORD;
    if _IsWindows8OrGreater() || (SUCCEEDED(DwmGetColorizationColor(*color, *opaque)) && !opaque) {
        region := CreateRectRgn(0, 0, -1, -1);
        bb: DWM_BLURBEHIND;
        bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
        bb.hRgnBlur = region;
        bb.fEnable = 1;
        DwmEnableBlurBehindWindow(cast(HWND)hwnd, *bb);
        DeleteObject(region);
    }
    else {
        bb: DWM_BLURBEHIND;
        bb.dwFlags = DWM_BB_ENABLE;
        DwmEnableBlurBehindWindow(cast(HWND)hwnd, *bb);
    }
}

#scope_file
// Backend data stored in io.BackendPlatformUserData to allow support for multiple Dear ImGui contexts
// It is STRONGLY preferred that you use docking branch with multi-viewports (== single Dear ImGui context + multiple windows) instead of multiple Dear ImGui contexts.
// FIXME: multi-context support is not well tested and probably dysfunctional in this backend.
// FIXME: some shared resources (mouse cursor shape, gamepad) are mishandled when using multi-context.
ImGui_ImplWin32_GetBackendData :: () -> *ImGui_ImplWin32_Data {
    return ifx ImGui.GetCurrentContext() then cast(*ImGui_ImplWin32_Data)ImGui.GetIO().BackendPlatformUserData else null;
}

ImGui_ImplWin32_InitEx :: (hwnd: *void, platform_has_own_dc: bool) -> bool {
    io := ImGui.GetIO();
    assert(io.BackendPlatformUserData == null, "Already initialized a platform backend!");

    perf_frequency: s64;
    perf_counter: s64;
    if !QueryPerformanceFrequency(*perf_frequency)
        return false;
    if !QueryPerformanceCounter(*perf_counter)
        return false;

    // Setup backend capabilities flags
    bd := cast(*ImGui_ImplWin32_Data)alloc(size_of(ImGui_ImplWin32_Data));
    io.BackendPlatformUserData = cast(*void)bd;
    io.BackendPlatformName = "imgui_impl_win32_jai";
    io.BackendFlags_ |= .ImGuiBackendFlags_HasMouseCursors; // We can honor GetMouseCursor() values (optional)
    io.BackendFlags_ |= .ImGuiBackendFlags_HasSetMousePos;  // We can honor io.WantSetMousePos requests (optional, rarely used)
    io.BackendFlags_ |= .ImGuiBackendFlags_PlatformHasViewports; // We can create multi-viewports on the Platform side (optional)
    io.BackendFlags_ |= .ImGuiBackendFlags_HasMouseHoveredViewport; // We can call io.AddMouseViewportEvent() with correct data (optional)

    bd.hWnd = cast(HWND)hwnd;
    bd.WantUpdateMonitors = true;
    bd.TicksPerSecond = perf_frequency;
    bd.Time = perf_counter;
    bd.LastMouseCursor = .COUNT;

    // Our mouse update function expect PlatformHandle to be filled for the main viewport
    main_viewport := ImGui.GetMainViewport();
    main_viewport.PlatformHandle    = cast(*void)bd.hWnd;
    main_viewport.PlatformHandleRaw = cast(*void)bd.hWnd;
    if io.ConfigFlags_ & .ImGuiConfigFlags_ViewportsEnable
        ImGui_ImplWin32_InitPlatformInterface(platform_has_own_dc);

    // Dynamically load XInput library
    bd.WantUpdateHasGamepad = true;
    // NOTE(Steven): Removed because Jai's Gamepad module will load the functions for us.

    return true;
}

ImGui_ImplWin32_UpdateMouseCursor :: () -> bool {
    io := ImGui.GetIO();
    if io.ConfigFlags_ & .ImGuiConfigFlags_NoMouseCursorChange
        return false;
    
    imgui_cursor := ImGui.GetMouseCursor();
    if imgui_cursor == .None || io.MouseDrawCursor {
        // Hide OS mouse cursor if imgui is drawing it or if it wants no cursor
        SetCursor(null);
    }
    else {
        // Show OS mouse cursor
        win32_cursor : *u8 = IDC_ARROW;
        if imgui_cursor == {
            case .Arrow;      win32_cursor = IDC_ARROW;
            case .TextInput;  win32_cursor = IDC_IBEAM;
            case .ResizeAll;  win32_cursor = IDC_SIZEALL;
            case .ResizeEW;   win32_cursor = IDC_SIZEWE;
            case .ResizeNS;   win32_cursor = IDC_SIZENS;
            case .ResizeNESW; win32_cursor = IDC_SIZENESW;
            case .ResizeNWSE; win32_cursor = IDC_SIZENWSE;
            case .Hand;       win32_cursor = IDC_HAND;
            case .NotAllowed; win32_cursor = IDC_NO;
        }
        SetCursor(LoadCursorA(null, win32_cursor));
    }

    return true;
}

IsVkDown :: (vk: s32) -> bool {
    return (GetKeyState(vk) & 0x8000) != 0;
}

ImGui_ImplWin32_AddKeyEvent :: (key: ImGui.Key, down: bool, native_keycode: s32, native_scancode: s32 = -1) {
    io := ImGui.GetIO();
    io.AddKeyEvent(io, key, down);
    io.SetKeyEventNativeData(io, key, native_keycode, native_scancode); // To support legacy indexing (<1.87 user code)
}

ImGui_ImplWin32_ProcessKeyEventsWorkarounds :: () {
    // Left & right Shift keys: when both are pressed together, Windows tend to not generate the WM_KEYUP event for the first released one.
    if ImGui.IsKeyDown(.ImGuiKey_LeftShift) && !IsVkDown(VK_LSHIFT)
        ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_LeftShift, false, VK_LSHIFT);
    if ImGui.IsKeyDown(.ImGuiKey_RightShift) && !IsVkDown(VK_RSHIFT)
        ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_RightShift, false, VK_RSHIFT);

    // Sometimes WM_KEYUP for Win key is not passed down to the app (e.g. for Win+V on some setups, according to GLFW).
    if ImGui.IsKeyDown(.ImGuiKey_LeftSuper) && !IsVkDown(VK_LWIN)
        ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_LeftSuper, false, VK_LWIN);
    if ImGui.IsKeyDown(.ImGuiKey_RightSuper) && !IsVkDown(VK_RWIN)
        ImGui_ImplWin32_AddKeyEvent(.ImGuiKey_RightSuper, false, VK_RWIN);
}

ImGui_ImplWin32_UpdateKeyModifiers :: () {
    io := ImGui.GetIO();
    io.AddKeyEvent(io, .ImGuiMod_Ctrl,  IsVkDown(VK_CONTROL));
    io.AddKeyEvent(io, .ImGuiMod_Shift, IsVkDown(VK_SHIFT));
    io.AddKeyEvent(io, .ImGuiMod_Alt,   IsVkDown(VK_MENU));
    io.AddKeyEvent(io, .ImGuiMod_Super, IsVkDown(VK_APPS));
}

// This code supports multi-viewports (multiple OS Windows mapped into different Dear ImGui viewports)
// Because of that, it is a little more complicated than your typical single-viewport binding code!
ImGui_ImplWin32_UpdateMouseData :: () {
    bd := ImGui_ImplWin32_GetBackendData();
    io := ImGui.GetIO();
    assert(bd.hWnd != null);

    mouse_screen_pos: POINT;
    has_mouse_screen_pos := GetCursorPos(*mouse_screen_pos) != 0;

    focused_window := GetForegroundWindow();
    is_app_focused := (focused_window && (focused_window == bd.hWnd || IsChild(focused_window, bd.hWnd) || ImGui.FindViewportByPlatformHandle(cast(*void)focused_window)));
    if is_app_focused {
        // (Optional) Set OS mouse position from Dear ImGui if requested (rarely used, only when ImGuiConfigFlags_NavEnableSetMousePos is enabled by user)
        // When multi-viewports are enabled, all Dear ImGui positions are same as OS positions.
        if io.WantSetMousePos {
            pos := POINT.{ cast(s32)io.MousePos.x, cast(s32)io.MousePos.y };
            if (io.ConfigFlags_ & .ImGuiConfigFlags_ViewportsEnable) == 0 {
                ClientToScreen(focused_window, *pos);
            }
            SetCursorPos(pos.x, pos.y);
        }

        // (Optional) Fallback to provide mouse position when focused (WM_MOUSEMOVE already provides this when hovered or captured)
        // This also fills a short gap when clicking non-client area: WM_NCMOUSELEAVE -> modal OS move -> gap -> WM_NCMOUSEMOVE
        if !io.WantSetMousePos && bd.MouseTrackedArea == 0 && has_mouse_screen_pos {
            // Single viewport mode: mouse position in client window coordinates (io.MousePos is (0,0) when the mouse is on the upper-left corner of the app window)
            // (This is the position you can get with ::GetCursorPos() + ::ScreenToClient() or WM_MOUSEMOVE.)
            // Multi-viewport mode: mouse position in OS absolute coordinates (io.MousePos is (0,0) when the mouse is on the upper-left of the primary monitor)
            // (This is the position you can get with ::GetCursorPos() or WM_MOUSEMOVE + ::ClientToScreen(). In theory adding viewport->Pos to a client position would also be the same.)
            mouse_pos: POINT = mouse_screen_pos;
            if !(io.ConfigFlags_ & .ImGuiConfigFlags_ViewportsEnable)
                ScreenToClient(bd.hWnd, *mouse_pos);
            io.AddMousePosEvent(io, cast(float)mouse_pos.x, cast(float)mouse_pos.y);
        }
    }

    // (Optional) When using multiple viewports: call io.AddMouseViewportEvent() with the viewport the OS mouse cursor is hovering.
    // If ImGuiBackendFlags_HasMouseHoveredViewport is not set by the backend, Dear imGui will ignore this field and infer the information using its flawed heuristic.
    // - [X] Win32 backend correctly ignore viewports with the _NoInputs flag (here using ::WindowFromPoint with WM_NCHITTEST + HTTRANSPARENT in WndProc does that)
    //       Some backend are not able to handle that correctly. If a backend report an hovered viewport that has the _NoInputs flag (e.g. when dragging a window
    //       for docking, the viewport has the _NoInputs flag in order to allow us to find the viewport under), then Dear ImGui is forced to ignore the value reported
    //       by the backend, and use its flawed heuristic to guess the viewport behind.
    // - [X] Win32 backend correctly reports this regardless of another viewport behind focused and dragged from (we need this to find a useful drag and drop target).
    mouse_viewport_id: ImGui.ID = 0;
    hovered_hwnd: HWND;
    viewport: *ImGui.Viewport;

    if has_mouse_screen_pos {
        hovered_hwnd = WindowFromPoint(mouse_screen_pos);
        if hovered_hwnd {
            viewport = ImGui.FindViewportByPlatformHandle(cast(*void)hovered_hwnd);
            if viewport {
                mouse_viewport_id = viewport.ID_;
            }
        }
    }
    io.AddMouseViewportEvent(io, mouse_viewport_id);
}

ImGui_ImplWin32_UpdateGamepads :: () {
    io := ImGui.GetIO();
    bd := ImGui_ImplWin32_GetBackendData();

    // Calling XInputGetState() every frame on disconnected gamepads is unfortunately too slow.
    // Instead we refresh gamepad availability by calling XInputGetCapabilities() _only_ after receiving WM_DEVICECHANGE.
    if bd.WantUpdateHasGamepad {
        state: XINPUT_STATE;
        // NOTE(Steven): The original ImGui BAckend used XInputGetCapabilities(), but since we depend
        // on the Jai Gamepad module, we will just leverage that it automatically pulls in XInputGetState() 
        // for us and use that.
        result := XInputGetState(0, *state);

        ERROR_DEVICE_NOT_CONNECTED :: 1167; // From winerror.h
        bd.HasGamepad = result != ERROR_DEVICE_NOT_CONNECTED;
        bd.WantUpdateHasGamepad = false;
    }

    io.BackendFlags_ &= ~.ImGuiBackendFlags_HasGamepad;
    xinput_state: XINPUT_STATE;
    gamepad := *xinput_state.Gamepad;
    if !bd.HasGamepad || XInputGetState(0, *xinput_state) != 0
        return;
    io.BackendFlags_ |= .ImGuiBackendFlags_HasGamepad;

    MAP_BUTTON :: (KEY_NO: ImGui.Key, BUTTON_ENUM: s64) #expand { `io.AddKeyEvent(`io, KEY_NO, (`gamepad.wButtons & BUTTON_ENUM) != 0); }
    MAP_ANALOG :: (KEY_NO: ImGui.Key, VALUE: s16, V0: s16, V1: s16) #expand { vn := cast(float32)(VALUE - V0) / cast(float32)(V1 - V0); `io.AddKeyAnalogEvent(`io, KEY_NO, vn > 0.10, saturate(vn)); }

    MAP_BUTTON(.ImGuiKey_GamepadStart,     XINPUT_GAMEPAD_START);
    MAP_BUTTON(.ImGuiKey_GamepadBack,      XINPUT_GAMEPAD_BACK);

    MAP_BUTTON(.ImGuiKey_GamepadFaceLeft,  XINPUT_GAMEPAD_X);
    MAP_BUTTON(.ImGuiKey_GamepadFaceRight, XINPUT_GAMEPAD_B);
    MAP_BUTTON(.ImGuiKey_GamepadFaceUp,    XINPUT_GAMEPAD_Y);
    MAP_BUTTON(.ImGuiKey_GamepadFaceDown,  XINPUT_GAMEPAD_A);

    MAP_BUTTON(.ImGuiKey_GamepadDpadLeft,  XINPUT_GAMEPAD_DPAD_LEFT);
    MAP_BUTTON(.ImGuiKey_GamepadDpadRight, XINPUT_GAMEPAD_DPAD_RIGHT);
    MAP_BUTTON(.ImGuiKey_GamepadDpadUp,    XINPUT_GAMEPAD_DPAD_UP);
    MAP_BUTTON(.ImGuiKey_GamepadDpadDown,  XINPUT_GAMEPAD_DPAD_DOWN);

    MAP_BUTTON(.ImGuiKey_GamepadL1,        XINPUT_GAMEPAD_LEFT_SHOULDER);
    MAP_BUTTON(.ImGuiKey_GamepadR1,        XINPUT_GAMEPAD_RIGHT_SHOULDER);

    MAP_ANALOG(.ImGuiKey_GamepadL2,          gamepad.bLeftTrigger,   XINPUT_GAMEPAD_TRIGGER_THRESHOLD,    255);
    MAP_ANALOG(.ImGuiKey_GamepadR2,          gamepad.bRightTrigger,  XINPUT_GAMEPAD_TRIGGER_THRESHOLD,    255);

    MAP_BUTTON(.ImGuiKey_GamepadL3,        XINPUT_GAMEPAD_LEFT_THUMB);
    MAP_BUTTON(.ImGuiKey_GamepadR3,        XINPUT_GAMEPAD_RIGHT_THUMB);

    MAP_ANALOG(.ImGuiKey_GamepadLStickLeft,  gamepad.sThumbLX,      -XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, -32768);
    MAP_ANALOG(.ImGuiKey_GamepadLStickRight, gamepad.sThumbLX,      +XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, +32767);
    MAP_ANALOG(.ImGuiKey_GamepadLStickUp,    gamepad.sThumbLY,      +XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, +32767);
    MAP_ANALOG(.ImGuiKey_GamepadLStickDown,  gamepad.sThumbLY,      -XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, -32768);

    // NOTE(Steven): The original imgui backend file uses XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE for left and right stick
    // inputs. Im not sure why this is... XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE does exist and is a slightly different
    // value. So we have opted to use the behavior that ImGui implemented to try to keep this faithful to that backend.
    MAP_ANALOG(.ImGuiKey_GamepadRStickLeft,  gamepad.sThumbRX,      -XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, -32768);
    MAP_ANALOG(.ImGuiKey_GamepadRStickRight, gamepad.sThumbRX,      +XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, +32767);
    MAP_ANALOG(.ImGuiKey_GamepadRStickUp,    gamepad.sThumbRY,      +XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, +32767);
    MAP_ANALOG(.ImGuiKey_GamepadRStickDown,  gamepad.sThumbRY,      -XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE, -32768);
}

GetMouseSourceFromMessageExtraInfo :: () -> ImGui.MouseSource {
    extra_info := GetMessageExtraInfo();

    if ((extra_info & 0xffffff80) == 0xff515700)
        return .ImGuiMouseSource_Pen;
    if ((extra_info & 0xffffff80) == 0xff515780)
        return .ImGuiMouseSource_TouchScreen;

    return .ImGuiMouseSource_Mouse;
}

ImGui_ImplWin32_VirtualKeyToImGuiKey :: (wParam: WPARAM) -> ImGui.Key {
    if wParam == {
        case VK_TAB; return .ImGuiKey_Tab;
        case VK_LEFT; return .ImGuiKey_LeftArrow;
        case VK_RIGHT; return .ImGuiKey_RightArrow;
        case VK_UP; return .ImGuiKey_UpArrow;
        case VK_DOWN; return .ImGuiKey_DownArrow;
        case VK_PRIOR; return .ImGuiKey_PageUp;
        case VK_NEXT; return .ImGuiKey_PageDown;
        case VK_HOME; return .ImGuiKey_Home;
        case VK_END; return .ImGuiKey_End;
        case VK_INSERT; return .ImGuiKey_Insert;
        case VK_DELETE; return .ImGuiKey_Delete;
        case VK_BACK; return .ImGuiKey_Backspace;
        case VK_SPACE; return .ImGuiKey_Space;
        case VK_RETURN; return .ImGuiKey_Enter;
        case VK_ESCAPE; return .ImGuiKey_Escape;
        case VK_OEM_7; return .ImGuiKey_Apostrophe;
        case VK_OEM_COMMA; return .ImGuiKey_Comma;
        case VK_OEM_MINUS; return .ImGuiKey_Minus;
        case VK_OEM_PERIOD; return .ImGuiKey_Period;
        case VK_OEM_2; return .ImGuiKey_Slash;
        case VK_OEM_1; return .ImGuiKey_Semicolon;
        case VK_OEM_PLUS; return .ImGuiKey_Equal;
        case VK_OEM_4; return .ImGuiKey_LeftBracket;
        case VK_OEM_5; return .ImGuiKey_Backslash;
        case VK_OEM_6; return .ImGuiKey_RightBracket;
        case VK_OEM_3; return .ImGuiKey_GraveAccent;
        case VK_CAPITAL; return .ImGuiKey_CapsLock;
        case VK_SCROLL; return .ImGuiKey_ScrollLock;
        case VK_NUMLOCK; return .ImGuiKey_NumLock;
        case VK_SNAPSHOT; return .ImGuiKey_PrintScreen;
        case VK_PAUSE; return .ImGuiKey_Pause;
        case VK_NUMPAD0; return .ImGuiKey_Keypad0;
        case VK_NUMPAD1; return .ImGuiKey_Keypad1;
        case VK_NUMPAD2; return .ImGuiKey_Keypad2;
        case VK_NUMPAD3; return .ImGuiKey_Keypad3;
        case VK_NUMPAD4; return .ImGuiKey_Keypad4;
        case VK_NUMPAD5; return .ImGuiKey_Keypad5;
        case VK_NUMPAD6; return .ImGuiKey_Keypad6;
        case VK_NUMPAD7; return .ImGuiKey_Keypad7;
        case VK_NUMPAD8; return .ImGuiKey_Keypad8;
        case VK_NUMPAD9; return .ImGuiKey_Keypad9;
        case VK_DECIMAL; return .ImGuiKey_KeypadDecimal;
        case VK_DIVIDE; return .ImGuiKey_KeypadDivide;
        case VK_MULTIPLY; return .ImGuiKey_KeypadMultiply;
        case VK_SUBTRACT; return .ImGuiKey_KeypadSubtract;
        case VK_ADD; return .ImGuiKey_KeypadAdd;
        case IM_VK_KEYPAD_ENTER; return .ImGuiKey_KeypadEnter;
        case VK_LSHIFT; return .ImGuiKey_LeftShift;
        case VK_LCONTROL; return .ImGuiKey_LeftCtrl;
        case VK_LMENU; return .ImGuiKey_LeftAlt;
        case VK_LWIN; return .ImGuiKey_LeftSuper;
        case VK_RSHIFT; return .ImGuiKey_RightShift;
        case VK_RCONTROL; return .ImGuiKey_RightCtrl;
        case VK_RMENU; return .ImGuiKey_RightAlt;
        case VK_RWIN; return .ImGuiKey_RightSuper;
        case VK_APPS; return .ImGuiKey_Menu;
        case #char "0"; return .ImGuiKey_0;
        case #char "1"; return .ImGuiKey_1;
        case #char "2"; return .ImGuiKey_2;
        case #char "3"; return .ImGuiKey_3;
        case #char "4"; return .ImGuiKey_4;
        case #char "5"; return .ImGuiKey_5;
        case #char "6"; return .ImGuiKey_6;
        case #char "7"; return .ImGuiKey_7;
        case #char "8"; return .ImGuiKey_8;
        case #char "9"; return .ImGuiKey_9;
        case #char "A"; return .ImGuiKey_A;
        case #char "B"; return .ImGuiKey_B;
        case #char "C"; return .ImGuiKey_C;
        case #char "D"; return .ImGuiKey_D;
        case #char "E"; return .ImGuiKey_E;
        case #char "F"; return .ImGuiKey_F;
        case #char "G"; return .ImGuiKey_G;
        case #char "H"; return .ImGuiKey_H;
        case #char "I"; return .ImGuiKey_I;
        case #char "J"; return .ImGuiKey_J;
        case #char "K"; return .ImGuiKey_K;
        case #char "L"; return .ImGuiKey_L;
        case #char "M"; return .ImGuiKey_M;
        case #char "N"; return .ImGuiKey_N;
        case #char "O"; return .ImGuiKey_O;
        case #char "P"; return .ImGuiKey_P;
        case #char "Q"; return .ImGuiKey_Q;
        case #char "R"; return .ImGuiKey_R;
        case #char "S"; return .ImGuiKey_S;
        case #char "T"; return .ImGuiKey_T;
        case #char "U"; return .ImGuiKey_U;
        case #char "V"; return .ImGuiKey_V;
        case #char "W"; return .ImGuiKey_W;
        case #char "X"; return .ImGuiKey_X;
        case #char "Y"; return .ImGuiKey_Y;
        case #char "Z"; return .ImGuiKey_Z;
        case VK_F1; return .ImGuiKey_F1;
        case VK_F2; return .ImGuiKey_F2;
        case VK_F3; return .ImGuiKey_F3;
        case VK_F4; return .ImGuiKey_F4;
        case VK_F5; return .ImGuiKey_F5;
        case VK_F6; return .ImGuiKey_F6;
        case VK_F7; return .ImGuiKey_F7;
        case VK_F8; return .ImGuiKey_F8;
        case VK_F9; return .ImGuiKey_F9;
        case VK_F10; return .ImGuiKey_F10;
        case VK_F11; return .ImGuiKey_F11;
        case VK_F12; return .ImGuiKey_F12;
        case; return .ImGuiKey_None;
    }
}

ImGui_ImplWin32_UpdateMonitors_EnumFunc :: (monitor: HMONITOR, hdc: HDC, rect: *RECT, lParam: LPARAM) -> BOOL #c_call {
    // ImVector calls need to allocate, so we need a context...
    // I am not sure how this is gonna work if you want to use a
    // different allocator with an ImVector...
    new_context: Context;
    push_context new_context {

        info: MONITORINFO;
        info.cbSize = size_of(MONITORINFO);
        if !GetMonitorInfoW(monitor, *info)
            return 1;
        using imgui_monitor: ImGui.PlatformMonitor;
        MainPos  = ImGui.ImVec2.{ cast(float)info.rcMonitor.left, cast(float)info.rcMonitor.top };
        MainSize = ImGui.ImVec2.{ cast(float)(info.rcMonitor.right - info.rcMonitor.left), cast(float)(info.rcMonitor.bottom - info.rcMonitor.top) };
        WorkPos  = ImGui.ImVec2.{ cast(float)info.rcWork.left, cast(float)info.rcWork.top };
        WorkSize = ImGui.ImVec2.{ cast(float)(info.rcWork.right -info.rcWork.left), cast(float)(info.rcWork.bottom - info.rcWork.top) };
        DpiScale = ImGui_ImplWin32_GetDpiScaleForMonitor(monitor);
        PlatformHandle = cast(*void)monitor;
        io := ImGui.GetPlatformIO();
        if info.dwFlags & MONITORINFOF_PRIMARY
            ImGui.ImVector_PushFront(*io.Monitors, *imgui_monitor); // TODO(Steven): I think this might have something to do with the ImGui crash we see when we call ImGui.DestroyContext()... Monitors is made in C++ land by ImGui, but then we are potentially allocating space in jai using our version of ImVector... We might need to try to use C++'s version of ImVector?
        else
            ImGui.ImVector_PushBack(*io.Monitors, *imgui_monitor); // Same as above TODO^
        return 1;
    
    }
}

ImGui_ImplWin32_UpdateMonitors :: () {
    bd := ImGui_ImplWin32_GetBackendData();
    ImGui.GetPlatformIO().Monitors.Size = 0; // NOTE(Steven): We did not bother implementing all the fancy methods ImVector has in C++. So this line replaces what should have been `ImGui.GetPlatformIO().Monitors.resize(0);`
    EnumDisplayMonitors(null, null, ImGui_ImplWin32_UpdateMonitors_EnumFunc, 0);
    bd.WantUpdateMonitors = false;
}

// NOTE(Steven): In the C++ code, this was a static variable inside the below
// function, since we dont have that, it is easier to make this a global variable
// and just not use it anywhere but the below function
RtlVerifyVersionInfo : (os_version_info: *OSVERSIONINFOEXW, version: s32, mask: u64) -> s32 #foreign;
_IsWindowsVersionOrGreater :: (major: WORD, minor: WORD, patch: WORD) -> BOOL {
    utf16_dll_name: *u16;

    new_context := context;
    new_context.allocator = temp; // utf8_to_wide will allocate, we want it to use the temporary allocator for this
    push_context new_context {
        utf16_dll_name = utf8_to_wide("ntdll.dll");
    }

    if !RtlVerifyVersionInfo {
        ntdllModule := GetModuleHandleW(utf16_dll_name);
        if ntdllModule
            RtlVerifyVersionInfo = xx GetProcAddress(ntdllModule, "RtlVerifyVersionInfo");
    }
    if RtlVerifyVersionInfo == null
        return 0;

    versionInfo: OSVERSIONINFOEXW;
    conditionMask : u64 = 0;
    versionInfo.dwOSVersionInfoSize = size_of(OSVERSIONINFOEXW);
    versionInfo.dwMajorVersion = major;
    versionInfo.dwMinorVersion = minor;
    conditionMask = VerSetConditionMask(conditionMask, VER_MAJORVERSION, VER_GREATER_EQUAL);
    conditionMask = VerSetConditionMask(conditionMask, VER_MINORVERSION, VER_GREATER_EQUAL);

    if RtlVerifyVersionInfo(*versionInfo, VER_MAJORVERSION | VER_MINORVERSION, conditionMask) == 0
        return 1;
    else
        return 0;
}

_IsWindowsVistaOrGreater ::   () -> BOOL #expand { return _IsWindowsVersionOrGreater(xx HIBYTE(0x0600), xx LOBYTE(0x0600), 0); } // _WIN32_WINNT_VISTA
_IsWindows8OrGreater ::       () -> BOOL #expand { return _IsWindowsVersionOrGreater(xx HIBYTE(0x0602), xx LOBYTE(0x0602), 0); } // _WIN32_WINNT_WIN8
_IsWindows8Point1OrGreater :: () -> BOOL #expand { return _IsWindowsVersionOrGreater(xx HIBYTE(0x0603), xx LOBYTE(0x0603), 0); } // _WIN32_WINNT_WINBLUE
_IsWindows10OrGreater ::      () -> BOOL #expand { return _IsWindowsVersionOrGreater(xx HIBYTE(0x0A00), xx LOBYTE(0x0A00), 0); } // _WIN32_WINNT_WINTHRESHOLD / _WIN32_WINNT_WIN10


// TODO(Steven): Do we need this???
// #ifndef DPI_ENUMS_DECLARED
// typedef enum { PROCESS_DPI_UNAWARE = 0, PROCESS_SYSTEM_DPI_AWARE = 1, PROCESS_PER_MONITOR_DPI_AWARE = 2 } PROCESS_DPI_AWARENESS;
// typedef enum { MDT_EFFECTIVE_DPI = 0, MDT_ANGULAR_DPI = 1, MDT_RAW_DPI = 2, MDT_DEFAULT = MDT_EFFECTIVE_DPI } MONITOR_DPI_TYPE;
// #endif
// #ifndef _DPI_AWARENESS_CONTEXTS_
// DECLARE_HANDLE(DPI_AWARENESS_CONTEXT);
// #define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE    (DPI_AWARENESS_CONTEXT)-3
// #endif
// #ifndef DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
// #define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (DPI_AWARENESS_CONTEXT)-4
// #endif
// typedef HRESULT(WINAPI* PFN_SetProcessDpiAwareness)(PROCESS_DPI_AWARENESS);                     // Shcore.lib + dll, Windows 8.1+
// typedef HRESULT(WINAPI* PFN_GetDpiForMonitor)(HMONITOR, MONITOR_DPI_TYPE, UINT*, UINT*);        // Shcore.lib + dll, Windows 8.1+
// typedef DPI_AWARENESS_CONTEXT(WINAPI* PFN_SetThreadDpiAwarenessContext)(DPI_AWARENESS_CONTEXT); // User32.lib + dll, Windows 10 v1607+ (Creators Update)

// For DPI functions that dynamically pull in some functions
user32_dll: HINSTANCE;
shcore_dll: HINSTANCE;

//---------------------------------------------------------------------------------------------------------
// MULTI-VIEWPORT / PLATFORM INTERFACE SUPPORT
// This is an _advanced_ and _optional_ feature, allowing the backend to create and handle multiple viewports simultaneously.
// If you are new to dear imgui or creating a new binding for dear imgui, it is recommended that you completely ignore this section first..
//--------------------------------------------------------------------------------------------------------

// Helper structure we store in the void* RendererUserData field of each ImGuiViewport to easily retrieve our backend data.
ImGui_ImplWin32_ViewportData :: struct {
    Hwnd: HWND;
    HwndParent: HWND;
    HwndOwned: bool;
    DwStyle: DWORD;
    DwExStyle: DWORD;
}

ImGui_ImplWin32_GetWin32StyleFromViewportFlags :: (flags: ImGui.ViewportFlags, out_style: *DWORD, out_ex_style: *DWORD) {
    if flags & .ImGuiViewportFlags_NoDecoration then
        <<out_style = WS_POPUP;
    else
        <<out_style = WS_OVERLAPPEDWINDOW;

    if flags & .ImGuiViewportFlags_NoTaskBarIcon then
        <<out_ex_style = WS_EX_TOOLWINDOW;
    else
        <<out_ex_style = WS_EX_APPWINDOW;

    if flags & .ImGuiViewportFlags_TopMost then
        <<out_ex_style |= WS_EX_TOPMOST;
}

ImGui_ImplWin32_GetHwndFromViewportID :: (viewport_id: ImGui.ID) -> HWND {
    if viewport_id != 0 {
        viewport := ImGui.FindViewportByID(viewport_id);
        if viewport
            return cast(HWND)viewport.PlatformHandle;
    }
    return null;
}

ImGui_ImplWin32_CreateWindow :: (viewport: *ImGui.Viewport) #c_call {
    ctx: Context;
    push_context ctx {
        vd: *ImGui_ImplWin32_ViewportData = alloc(size_of(ImGui_ImplWin32_ViewportData));
        viewport.PlatformUserData = vd;

        window_class_name: *u16;
        window_title: *u16;

        new_context := context;
        new_context.allocator = temp;
        push_context new_context { // The window class name and title need to be utf16 string, use the temporary allocator to create them
            window_class_name = utf8_to_wide("ImGui Platform");
            window_title      = utf8_to_wide("Untitled");
        }

        // Select style and parent window
        ImGui_ImplWin32_GetWin32StyleFromViewportFlags(viewport.Flags, *vd.DwStyle, *vd.DwExStyle);
        vd.HwndParent = ImGui_ImplWin32_GetHwndFromViewportID(viewport.ParentViewportId);

        // Create window
        rect := RECT.{ cast(s32)viewport.Pos.x, cast(s32)viewport.Pos.y, cast(s32)(viewport.Pos.x + viewport.Size.x), cast(s32)(viewport.Pos.y + viewport.Size.y) };
        AdjustWindowRectEx(*rect, vd.DwStyle, 0, xx vd.DwExStyle);
        vd.Hwnd = CreateWindowExW(
            xx vd.DwExStyle, window_class_name, window_title, vd.DwStyle,        // Style, class name, window name,
            rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, // Window area
            vd.HwndParent, null, GetModuleHandleW(null), null                    // Owner window, menu, Instance, Param
        );
        vd.HwndOwned = true;
        viewport.PlatformRequestResize = false;
        viewport.PlatformHandle = vd.Hwnd;
        viewport.PlatformHandleRaw = vd.Hwnd;
    }
}

ImGui_ImplWin32_DestroyWindow :: (viewport: *ImGui.Viewport) #c_call {
    ctx: Context;
    push_context ctx {
        bd := ImGui_ImplWin32_GetBackendData();
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        if vd {
            if GetCapture() == vd.Hwnd {
                // Transfer capture so if we started dragging from a window that later disappears, we'll still recieve the MOUSEUP event.
                ReleaseCapture();
                SetCapture(bd.hWnd);
            }
            if vd.Hwnd && vd.HwndOwned
                DestroyWindow(vd.Hwnd);
            vd.Hwnd = null;
            free(vd);
        }
        viewport.PlatformUserData = null;
        viewport.PlatformHandle = null;
    }
}

ImGui_ImplWin32_ShowWindow :: (viewport: *ImGui.Viewport) #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);

        if viewport.Flags & .ImGuiViewportFlags_NoFocusOnAppearing
            ShowWindow(vd.Hwnd, SW_SHOWNA);
        else
            ShowWindow(vd.Hwnd, SW_SHOW);
    }
}

ImGui_ImplWin32_UpdateWindow :: (viewport: *ImGui.Viewport) #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);

        // Update Win32 parent if it changed _after_ creation
        // Unlike style settings derived from configuration flags, this is more likely to change for advanced apps that are manipulating ParentViewportID manually.
        new_parent := ImGui_ImplWin32_GetHwndFromViewportID(viewport.ParentViewportId);
        if new_parent != vd.HwndParent {
            // Win32 windows can either have a "Parent" (for WS_CHILD window) or an "Owner" (which among other thing keeps window above its owner).
            // Our Dear Imgui-side concept of parenting only mostly care about what Win32 call "Owner".
            // The parent parameter of CreateWindowEx() sets up Parent OR Owner depending on WS_CHILD flag. In our case an Owner as we never use WS_CHILD.
            // Calling ::SetParent() here would be incorrect: it will create a full child relation, alter coordinate system and clipping.
            // Calling ::SetWindowLongPtr() with GWLP_HWNDPARENT seems correct although poorly documented.
            // https://devblogs.microsoft.com/oldnewthing/20100315-00/?p=14613
            vd.HwndParent = new_parent;
            SetWindowLongPtrW(vd.Hwnd, GWLP_HWNDPARENT, cast(s64)vd.HwndParent);
        }

        // (Optional) Update Win32 style if it changed _after_ creation.
        // Generally they won't change unless configuration flags are changed, but advanced uses (such as manually rewriting viewport flags) make this useful.
        new_style: DWORD;
        new_ex_style: DWORD;
        ImGui_ImplWin32_GetWin32StyleFromViewportFlags(viewport.Flags, *new_style, *new_ex_style);

        // Only reapply the flags that have been changed from our point of view (as other flags are being modified by Windows)
        if vd.DwStyle != new_style || vd.DwExStyle != new_ex_style {
            // (Optional) Update TopMost state if it changed _after_ creation
            top_most_changed := (vd.DwExStyle & WS_EX_TOPMOST) != (new_ex_style & WS_EX_TOPMOST);
            insert_after: HWND = ifx top_most_changed then (ifx viewport.Flags & .ImGuiViewportFlags_TopMost then HWND_TOPMOST else HWND_NOTOPMOST) else null;
            swp_flag: u32 = ifx top_most_changed then cast(u32)0 else SWP_NOZORDER;

            // Apply flags and position (since it is affected by flags)
            vd.DwStyle = new_style;
            vd.DwExStyle = new_ex_style;
            SetWindowLongW(vd.Hwnd, GWL_STYLE, xx vd.DwStyle);
            SetWindowLongW(vd.Hwnd, GWL_EXSTYLE, xx vd.DwExStyle);
            rect := RECT.{ cast(s32)viewport.Pos.x, cast(s32)viewport.Pos.y, cast(s32)(viewport.Pos.x + viewport.Size.x), cast(s32)(viewport.Pos.y + viewport.Size.y) };
            AdjustWindowRectEx(*rect, vd.DwStyle, 0, xx vd.DwExStyle); // Client to Screen
            SetWindowPos(vd.Hwnd, insert_after, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, swp_flag | SWP_NOACTIVATE | SWP_FRAMECHANGED);
            ShowWindow(vd.Hwnd, SW_SHOWNA); // This is necessary when we alter the style
            viewport.PlatformRequestMove = true;
            viewport.PlatformRequestResize = true;
        }
    }
}

ImGui_ImplWin32_GetWindowPos :: (viewport: *ImGui.Viewport) -> ImGui.ImVec2 #c_call #cpp_return_type_is_non_pod {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        pos: POINT;
        ClientToScreen(vd.Hwnd, *pos);
        return ImGui.ImVec2.{ cast(float)pos.x, cast(float)pos.y };
    }
}

ImGui_ImplWin32_SetWindowPos :: (viewport: *ImGui.Viewport, pos: ImGui.ImVec2) #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        rect := RECT.{ cast(s32)pos.x, cast(s32)pos.y, cast(s32)pos.x, cast(s32)pos.y };
        AdjustWindowRectEx(*rect, vd.DwStyle, 0, xx vd.DwExStyle);
        SetWindowPos(vd.Hwnd, null, rect.left, rect.top, 0, 0, SWP_NOZORDER | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}

ImGui_ImplWin32_GetWindowSize :: (viewport: *ImGui.Viewport) -> ImGui.ImVec2 #c_call #cpp_return_type_is_non_pod {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        rect: RECT;
        GetClientRect(vd.Hwnd, *rect);
        return ImGui.ImVec2.{ cast(float)(rect.right - rect.left), cast(float)(rect.bottom - rect.top) };
    }
}

ImGui_ImplWin32_SetWindowSize :: (viewport: *ImGui.Viewport, size: ImGui.ImVec2) #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        rect := RECT.{ 0, 0, cast(s32)size.x, cast(s32)size.y };
        AdjustWindowRectEx(*rect, vd.DwStyle, 0, xx vd.DwExStyle); // Client to Screen
        SetWindowPos(vd.Hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, SWP_NOZORDER | SWP_NOMOVE | SWP_NOACTIVATE);
    }
}

ImGui_ImplWin32_SetWindowFocus :: (viewport: *ImGui.Viewport) #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        BringWindowToTop(vd.Hwnd);
        SetForegroundWindow(vd.Hwnd);
        SetFocus(vd.Hwnd);
    }
}

ImGui_ImplWin32_GetWindowFocus :: (viewport: *ImGui.Viewport) -> bool #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        return GetForegroundWindow() == vd.Hwnd;
    }
}

ImGui_ImplWin32_GetWindowMinimized :: (viewport: *ImGui.Viewport) -> bool #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        return IsIconic(vd.Hwnd) != 0;
    }
}

ImGui_ImplWin32_SetWindowTitle :: (viewport: *ImGui.Viewport, title: *u8) #c_call {
    ctx: Context;
    push_context ctx {
        // ::SetWindowTextA() doesn't properly handle UTF-8 so we explicitely convert our string.
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);

        n: s32 = MultiByteToWideChar(CP_UTF8, 0, title, -1, null, 0);
        title_w: ImGui.ImVector(u16);
        ImGui.ImVector_Reserve(*title_w, n); // TODO(Steven): Is reserve good enough for this? Or do we need the full resize() here?
        MultiByteToWideChar(CP_UTF8, 0, title, -1, title_w.Data, n);
        SetWindowTextW(vd.Hwnd, title_w.Data);

        free(title_w.Data); // We need to free manually! We dont have destructors in Jai
    }
}

ImGui_ImplWin32_SetWindowAlpha :: (viewport: *ImGui.Viewport, alpha: float) #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        assert(alpha >= 0.0 && alpha <= 1.0);

        if alpha < 1.0 {
            style: s32 = GetWindowLongW(vd.Hwnd, GWL_EXSTYLE) | WS_EX_LAYERED;
            SetWindowLongW(vd.Hwnd, GWL_EXSTYLE, style);
            SetLayeredWindowAttributes(vd.Hwnd, 0, cast(u8)(255*alpha), LWA_ALPHA);
        }
        else {
            style: s32 = xx (GetWindowLongW(vd.Hwnd, GWL_EXSTYLE) & ~WS_EX_LAYERED);
            SetWindowLongW(vd.Hwnd, GWL_EXSTYLE, style);
        }
    }
}

ImGui_ImplWin32_GetWindowDpiScale :: (viewport: *ImGui.Viewport) -> float #c_call {
    ctx: Context;
    push_context ctx {
        vd := cast(*ImGui_ImplWin32_ViewportData)viewport.PlatformUserData;
        assert(vd.Hwnd != null);
        return ImGui_ImplWin32_GetDpiScaleForHwnd(vd.Hwnd);
    }
}

// FIXME-DPI: Testing DPI related ideas
ImGui_ImplWin32_OnChangedViewport :: (viewport: *ImGui.Viewport) #c_call {
    // This function has a commented out body in the source C++ file
}

ImGui_ImplWin32_WndProcHandler_PlatformWindow :: (hWnd: HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call {
    if ImGui_ImplWin32_WindowProc(hWnd, msg, wParam, lParam)
        return 1;
    
    viewport := ImGui.FindViewportByPlatformHandle(cast(*void)hWnd);
    if viewport {
        if msg == {
            case WM_CLOSE;
                viewport.PlatformRequestClose = true;
                return 0;

            case WM_MOVE;
                viewport.PlatformRequestMove = true;

            case WM_SIZE;
                viewport.PlatformRequestResize = true;

            case WM_MOUSEACTIVATE;
                if viewport.Flags & .ImGuiViewportFlags_NoFocusOnClick
                    return MA_NOACTIVATE;

            case WM_NCHITTEST;
                // Let mouse pass-through the window. This will allow the backend to call io.AddMouseViewportEvent() correctly. (which is optional).
                // The ImGuiViewportFlags_NoInputs flag is set while dragging a viewport, as want to detect the window behind the one we are dragging.
                // If you cannot easily access those viewport flags from your windowing/event code: you may manually synchronize its state e.g. in
                // your main loop after calling UpdatePlatformWindows(). Iterate all viewports/platform windows and pass the flag to your windowing system.
                if viewport.Flags & .ImGuiViewportFlags_NoInputs
                    return HTTRANSPARENT;
        }
    }

    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

ImGui_ImplWin32_InitPlatformInterface :: (platform_has_own_dc: bool) {
    window_class_name: *u16;

    new_context := context;
    new_context.allocator = temp;
    push_context new_context { // The window class name needs to be a utf16 string, use the temporary allocator to create it
        window_class_name = utf8_to_wide("ImGui Platform");
    }

    {
        using wcex: WNDCLASSEXW;
        cbSize = size_of(WNDCLASSEXW);
        style = CS_HREDRAW | CS_VREDRAW | ifx platform_has_own_dc then CS_OWNDC else cast(u32)0;
        lpfnWndProc = xx ImGui_ImplWin32_WndProcHandler_PlatformWindow;
        cbClsExtra = 0;
        cbWndExtra = 0;
        hInstance = GetModuleHandleW(null);
        hIcon = null;
        hCursor = null;
        hbrBackground = cast(HBRUSH)(COLOR_BACKGROUND + 1);
        lpszClassName = window_class_name;
        hIconSm = null;
        RegisterClassExW(*wcex);
    }

    ImGui_ImplWin32_UpdateMonitors();

    // Register platform interface (will be coupled with a renderer interface)
    platform_io := ImGui.GetPlatformIO();
    platform_io.Platform_CreateWindow       = ImGui_ImplWin32_CreateWindow;
    platform_io.Platform_DestroyWindow      = ImGui_ImplWin32_DestroyWindow;
    platform_io.Platform_ShowWindow         = ImGui_ImplWin32_ShowWindow;
    platform_io.Platform_SetWindowPos       = ImGui_ImplWin32_SetWindowPos;
    platform_io.Platform_GetWindowPos       = ImGui_ImplWin32_GetWindowPos;
    platform_io.Platform_SetWindowSize      = ImGui_ImplWin32_SetWindowSize;
    platform_io.Platform_GetWindowSize      = ImGui_ImplWin32_GetWindowSize;
    platform_io.Platform_SetWindowFocus     = ImGui_ImplWin32_SetWindowFocus;
    platform_io.Platform_GetWindowFocus     = ImGui_ImplWin32_GetWindowFocus;
    platform_io.Platform_GetWindowMinimized = ImGui_ImplWin32_GetWindowMinimized;
    platform_io.Platform_SetWindowTitle     = ImGui_ImplWin32_SetWindowTitle;
    platform_io.Platform_SetWindowAlpha     = ImGui_ImplWin32_SetWindowAlpha;
    platform_io.Platform_UpdateWindow       = ImGui_ImplWin32_UpdateWindow;
    platform_io.Platform_GetWindowDpiScale  = ImGui_ImplWin32_GetWindowDpiScale; // FIXME-DPI
    platform_io.Platform_OnChangedViewport  = ImGui_ImplWin32_OnChangedViewport; // FIXME-DPI

    // Register main window handle (which is owned by the main application, not by us)
    // This is mostly for simplicity and consistency, so that our code (e.g. mouse handling etc.) can use same logic for main and secondary viewports.
    main_viewport := ImGui.GetMainViewport();
    bd := ImGui_ImplWin32_GetBackendData();
    vd := cast(*ImGui_ImplWin32_ViewportData)alloc(size_of(ImGui_ImplWin32_ViewportData));
    vd.Hwnd = bd.hWnd;
    vd.HwndOwned = false;
    main_viewport.PlatformUserData = vd;
    main_viewport.PlatformHandle = cast(*void)bd.hWnd;
}

ImGui_ImplWin32_ShutdownPlatformInterface :: () {
    window_class_name: *u16;

    new_context := context;
    new_context.allocator = temp;
    push_context new_context { // The window class name needs to be a utf16 string, use the temporary allocator to create it
        window_class_name = utf8_to_wide("ImGui Platform");
    }

    UnregisterClassW(window_class_name, GetModuleHandleW(null));
    ImGui.DestroyPlatformWindows();
}


// There is no distinct VK_xxx for keypad enter, instead it is VK_RETURN + KF_EXTENDED, we assign it an arbitrary value to make code more readable (VK_ codes go up to 255)
IM_VK_KEYPAD_ENTER :: (VK_RETURN + 256);

// Below are Windows specific things that are not exposed in Jai's windows module yet
user32 :: #system_library "user32";
kernel32 :: #system_library "kernel32";
gdi32 :: #system_library "Gdi32";
dwmapi :: #system_library "Dwmapi";
SetCursorPos :: (x: s32, y: s32) #foreign user32;
TrackMouseEvent :: (track_mouse_event: *TRACKMOUSEEVENT) -> bool #foreign user32;
GetCapture :: () -> HWND #foreign user32;
ReleaseCapture :: () -> bool #foreign user32;
IsWindowUnicode :: (hwnd: HWND) -> bool #foreign user32;
IsChild :: (hWndParent: HWND, hWnd: HWND) -> bool #foreign user32;
VerSetConditionMask :: (ConditionMask: u64, TypeMask: DWORD, Condition: u8) -> u64 #foreign kernel32;
DwmGetColorizationColor :: (pcrColorization: *DWORD, pfOpaqueBlend: *BOOL) -> HRESULT #foreign dwmapi;
DwmEnableBlurBehindWindow :: (hwnd: HWND, pBlurBehind: *DWM_BLURBEHIND) -> HRESULT #foreign dwmapi;
CreateRectRgn :: (x1: s32, y1: s32, x2: s32, y2: s32) -> HRGN #foreign gdi32;
BringWindowToTop :: (hwnd: HWND) -> BOOL #foreign user32;
SetForegroundWindow :: (hwnd: HWND) -> BOOL #foreign user32;
SetFocus :: (hwnd: HWND) -> HWND #foreign user32;
SetLayeredWindowAttributes :: (hwnd: HWND, crKey: DWORD, bAlpha: u8, dwFlags: DWORD) -> BOOL #foreign user32;
IsIconic :: (hwnd: HWND) -> BOOL #foreign user32;
UnregisterClassW :: (lpszClassName: *u16, hInstance: HINSTANCE) -> BOOL #foreign user32;

HRGN :: HANDLE;

TRACKMOUSEEVENT :: struct {
    cbSize: DWORD;
    dwFlags: DWORD;
    hwndTrack: HWND;
    dwHoverTime: DWORD;
}

DWM_BLURBEHIND :: struct {
    dwFlags: DWORD;
    fEnable: BOOL;
    hRgnBlur: HRGN;
    fTransitionOnMaximized: BOOL;
}


COLOR_BACKGROUND :: 1;

HTTRANSPARENT :: -1;
MA_NOACTIVATE :: 3;

LWA_ALPHA :: 0x00000002;

DWM_BB_ENABLE :: 0x00000001;
DWM_BB_BLURREGION :: 0x00000002;

VER_MINORVERSION :: 0x0000001;
VER_MAJORVERSION :: 0x0000002;
VER_GREATER_EQUAL :: 3;

MONITORINFOF_PRIMARY :: 0x00000001;

WM_DEVICECHANGE :: 0x0219;
DBT_DEVNODES_CHANGED :: 0x0007;

MB_PRECOMPOSED :: 0x00000001;

KF_EXTENDED :: 0x0100;

XBUTTON1    :: 0x0001;
WHEEL_DELTA :: 120;

TME_CANCEL    :: 0x80000000;
TME_HOVER     :: 0x00000001;
TME_LEAVE     :: 0x00000002;
TME_NONCLIENT :: 0x00000010;
TME_QUERY     :: 0x40000000;

WM_MOUSELEAVE   :: 0x02A3;
WM_NCMOUSELEAVE :: 0x02A2;

GWLP_HWNDPARENT :: -8;

HTCLIENT :: 1;

LOWORD :: (x: s64) -> s16 #expand {
    return cast,no_check(s16)((x) & 0x0000_0000_0000_ffff);
}

HIWORD :: (x: s64) -> s16 #expand {
    return cast,no_check(s16)((x >> 16) & 0x0000_0000_0000_ffff);
}

LOBYTE :: (x: s64) -> s8 #expand {
    return cast,no_check(s8)(x & 0x0000_0000_0000_00ff);
}
HIBYTE :: (x: s64) -> s8 #expand {
    return cast,no_check(s8)((x >> 8) & 0x0000_0000_0000_00ff);
}

#import "Basic";
#import "Windows";
#import "Windows_Utf8";
#import "Gamepad";
#import "Math"; // For FLOAT32_MAX
ImGui :: #import "ImGui";
