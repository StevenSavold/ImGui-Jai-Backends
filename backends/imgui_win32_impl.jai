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

    // Unload XInput library
    // NOTE(Steven): Removed because we never loaded this ourselves.

    io.BackendPlatformName = null;
    io.BackendPlatformUserData = null;
    io.BackendFlags_ &= ~(.HasMouseCursors | .HasSetMousePos | .HasGamepad);
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
                if !(message == WM_NCMOUSEMOVE && ScreenToClient(hwnd, *mouse_pos) == 0) { // WM_NCMOUSEMOVE are provided in absolute coordinates.
                    io.AddMouseSourceEvent(io, mouse_source);
                    io.AddMousePosEvent(io, cast(float)mouse_pos.x, cast(float)mouse_pos.y);
                }

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
        }

        return 0;
    }
}

// TODO(Steven): Add the DPI support stuff

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

    bd.hWnd = cast(HWND)hwnd;
    bd.TicksPerSecond = perf_frequency;
    bd.Time = perf_counter;
    bd.LastMouseCursor = .COUNT;

    // Set platform dependent data in viewport
    ImGui.GetMainViewport().PlatformHandleRaw = cast(*void)hwnd;
    // platform_has_own_dc is used in 'docking' branch.

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
        // Show OS mousr cursor
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

ImGui_ImplWin32_UpdateMouseData :: () {
    bd := ImGui_ImplWin32_GetBackendData();
    io := ImGui.GetIO();
    assert(bd.hWnd != null);

    focused_window := GetForegroundWindow();
    is_app_focused := (focused_window == bd.hWnd);
    if is_app_focused {
        // (Optional) Set OS mouse position from Dear ImGui if requested (rarely used, only when ImGuiConfigFlags_NavEnableSetMousePos is enabled by user)
        if io.WantSetMousePos {
            pos := POINT.{ cast(s32)io.MousePos.x, cast(s32)io.MousePos.y };
            if ClientToScreen(bd.hWnd, *pos) {
                SetCursorPos(pos.x, pos.y);
            }
        }

        // (Optional) Fallback to provide mouse position when focused (WM_MOUSEMOVE already provides this when hovered or captured)
        // This also fills a short gap when clicking non-client area: WM_NCMOUSELEAVE -> modal OS move -> gap -> WM_NCMOUSEMOVE
        if !io.WantSetMousePos && bd.MouseTrackedArea == 0 {
            pos: POINT;
            if GetCursorPos(*pos) && ScreenToClient(bd.hWnd, *pos)
                io.AddMousePosEvent(io, cast(float)pos.x, cast(float)pos.y);
        }
    }
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

// There is no distinct VK_xxx for keypad enter, instead it is VK_RETURN + KF_EXTENDED, we assign it an arbitrary value to make code more readable (VK_ codes go up to 255)
IM_VK_KEYPAD_ENTER :: (VK_RETURN + 256);

// Below are Windows specific things that are not exposed in Jai's windows module yet
user32 :: #system_library "user32";
SetCursorPos :: (x: s32, y: s32) #foreign user32;
TrackMouseEvent :: (track_mouse_event: *TRACKMOUSEEVENT) -> bool #foreign user32;
GetCapture :: () -> HWND #foreign user32;
ReleaseCapture :: () -> bool #foreign user32;
IsWindowUnicode :: (hwnd: HWND) -> bool #foreign user32;

TRACKMOUSEEVENT :: struct {
    cbSize: DWORD;
    dwFlags: DWORD;
    hwndTrack: HWND;
    dwHoverTime: DWORD;
}

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

#import "Basic";
#import "Windows";
#import "Gamepad";
#import "Math"; // For FLOAT32_MAX
ImGui :: #import "ImGui";
