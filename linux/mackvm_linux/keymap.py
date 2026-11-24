"""macOS CGKeyCode -> Linux X11 keycode (evdev + 8) and mouse button translation."""

from __future__ import annotations

# Base Linux evdev keycodes (X11 keycode = evdev + 8).
# Ref: linux/input-event-codes.h & Apple Carbon Events HIToolbox kVK_* constants.
_MAC_TO_EVDEV: dict[int, int] = {
    # Letters (ANSI layout)
    0x00: 30,  # A
    0x01: 31,  # S
    0x02: 32,  # D
    0x03: 33,  # F
    0x04: 35,  # H
    0x05: 34,  # G
    0x06: 44,  # Z
    0x07: 45,  # X
    0x08: 46,  # C
    0x09: 47,  # V
    0x0A: 86,  # ISO Section
    0x0B: 48,  # B
    0x0C: 16,  # Q
    0x0D: 17,  # W
    0x0E: 18,  # E
    0x0F: 19,  # R
    0x10: 21,  # Y
    0x11: 20,  # T
    0x12: 2,   # 1
    0x13: 3,   # 2
    0x14: 4,   # 3
    0x15: 5,   # 4
    0x16: 7,   # 6
    0x17: 6,   # 5
    0x18: 13,  # Equal (=)
    0x19: 10,  # 9
    0x1A: 8,   # 7
    0x1B: 12,  # Minus (-)
    0x1C: 9,   # 8
    0x1D: 11,  # 0
    0x1E: 27,  # RightBracket (])
    0x1F: 24,  # O
    0x20: 22,  # U
    0x21: 26,  # LeftBracket ([)
    0x22: 23,  # I
    0x23: 25,  # P
    0x24: 28,  # Return
    0x25: 38,  # L
    0x26: 36,  # J
    0x27: 40,  # Quote (')
    0x28: 37,  # K
    0x29: 39,  # Semicolon (;)
    0x2A: 43,  # Backslash (\)
    0x2B: 51,  # Comma (,)
    0x2C: 53,  # Slash (/)
    0x2D: 49,  # N
    0x2E: 50,  # M
    0x2F: 52,  # Period (.)
    0x30: 15,  # Tab
    0x31: 57,  # Space
    0x32: 41,  # Grave (`)
    0x33: 14,  # Delete (Backspace)
    0x35: 1,   # Escape
    0x39: 58,  # CapsLock

    # Modifiers (default unswapped: Cmd -> Super, Ctrl -> Control)
    0x36: 126, # Right Command -> KEY_RIGHTMETA
    0x37: 125, # Left Command  -> KEY_LEFTMETA
    0x38: 42,  # Left Shift    -> KEY_LEFTSHIFT
    0x3A: 56,  # Left Option   -> KEY_LEFTALT
    0x3B: 29,  # Left Control  -> KEY_LEFTCTRL
    0x3C: 54,  # Right Shift   -> KEY_RIGHTSHIFT
    0x3D: 100, # Right Option  -> KEY_RIGHTALT
    0x3E: 97,  # Right Control -> KEY_RIGHTCTRL

    # Keypad
    0x41: 83,  # KP_Decimal
    0x43: 55,  # KP_Multiply
    0x45: 78,  # KP_Plus
    0x47: 69,  # KP_Clear / NumLock
    0x4B: 98,  # KP_Divide
    0x4C: 96,  # KP_Enter
    0x4E: 74,  # KP_Minus
    0x51: 117, # KP_Equal
    0x52: 82,  # KP_0
    0x53: 79,  # KP_1
    0x54: 80,  # KP_2
    0x55: 81,  # KP_3
    0x56: 75,  # KP_4
    0x57: 76,  # KP_5
    0x58: 77,  # KP_6
    0x59: 71,  # KP_7
    0x5B: 72,  # KP_8
    0x5C: 73,  # KP_9

    # Function keys & Navigation
    0x60: 63,  # F5
    0x61: 64,  # F6
    0x62: 65,  # F7
    0x63: 61,  # F3
    0x64: 66,  # F8
    0x65: 67,  # F9
    0x67: 87,  # F11
    0x69: 99,  # F13 / PrintScreen
    0x6A: 186, # F16
    0x6B: 70,  # F14 / ScrollLock
    0x6D: 68,  # F10
    0x6E: 127, # Context Menu
    0x6F: 88,  # F12
    0x71: 119, # F15 / Pause
    0x72: 110, # Help / Insert
    0x73: 102, # Home
    0x74: 104, # PageUp
    0x75: 111, # ForwardDelete
    0x76: 62,  # F4
    0x77: 107, # End
    0x78: 60,  # F2
    0x79: 109, # PageDown
    0x7A: 59,  # F1
    0x7B: 105, # Left
    0x7C: 106, # Right
    0x7D: 108, # Down
    0x7E: 103, # Up

    # NX_SYSDEFINED media keys (encoded by ControllerRole as 0xFF00 | nx_key)
    0xFF00 | 0x00: 115, # NX_KEYTYPE_SOUND_UP -> KEY_VOLUMEUP
    0xFF00 | 0x01: 114, # NX_KEYTYPE_SOUND_DOWN -> KEY_VOLUMEDOWN
    0xFF00 | 0x02: 225, # NX_KEYTYPE_BRIGHTNESS_UP
    0xFF00 | 0x03: 224, # NX_KEYTYPE_BRIGHTNESS_DOWN
    0xFF00 | 0x07: 113, # NX_KEYTYPE_MUTE -> KEY_MUTE
    0xFF00 | 0x10: 164, # NX_KEYTYPE_PLAY -> KEY_PLAYPAUSE
    0xFF00 | 0x11: 163, # NX_KEYTYPE_NEXT -> KEY_NEXTSONG
    0xFF00 | 0x12: 165, # NX_KEYTYPE_PREVIOUS -> KEY_PREVIOUSSONG
    0xFF00 | 0x13: 163, # NX_KEYTYPE_FAST
    0xFF00 | 0x14: 165, # NX_KEYTYPE_REWIND
}

_SWAP_MODIFIERS = {
    0x37: 29,  # Left Cmd  -> KEY_LEFTCTRL
    0x36: 97,  # Right Cmd -> KEY_RIGHTCTRL
    0x3B: 125, # Left Ctrl -> KEY_LEFTMETA (Super_L)
    0x3E: 126, # Right Ctrl -> KEY_RIGHTMETA (Super_R)
}

SHIFT_MAC_KEYCODES = {0x38, 0x3C}


def mac_keycode_to_x11(mac_keycode: int, swap_cmd_ctrl: bool = True) -> int | None:
    if swap_cmd_ctrl and mac_keycode in _SWAP_MODIFIERS:
        return _SWAP_MODIFIERS[mac_keycode] + 8
    evdev = _MAC_TO_EVDEV.get(mac_keycode)
    return (evdev + 8) if evdev is not None else None


def mac_button_to_x11(button_number: int) -> int | None:
    mapping = {
        0: 1,  # Left
        1: 3,  # Right
        2: 2,  # Middle
        3: 8,  # Back
        4: 9,  # Forward
    }
    return mapping.get(button_number)
