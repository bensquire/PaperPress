---
title: The Shortcuts and Menus Every Mac User Knows
impact: HIGH
impactDescription: An invented shortcut is one the user has to learn; a missing menu item is one they cannot find
tags: [native, macos, keyboard, shortcuts, menus]
paths: ["Sources/PressApp/**/*.swift", "Sources/PaperPress/**/*.swift"]
---

## The Shortcuts and Menus Every Mac User Knows

**Impact: HIGH**

Every action the user can take from a button can be taken from the menu bar,
and the common ones carry the platform's shortcut:

| Action | Shortcut |
|---|---|
| Open PDFs or a folder | ⌘O |
| Convert… | ⌘↩ |
| Quick Look the selected file | Space |
| Confirm, cancel | Return, Escape |
| Settings | ⌘, |
| Close, minimise, hide, quit | ⌘W, ⌘M, ⌘H, ⌘Q — never overridden; ⌘Q asks while batches are unfinished |

A new action takes the shortcut the platform's guidelines give it, or none. A
shortcut is never invented where Apple has assigned one, and never reused for a
second meaning. Menus are the standard set in the standard order — App, File,
Edit, View, Window, Help — with the app's items placed in the group they belong
to: Open… and Convert… sit in File. This table states the
convention; not every row exists in the app yet — today the queue's Pause,
Resume and Clear, and the review's All and None, are buttons only.

**Incorrect (a new top-level menu for two items; a shortcut with a meaning of its own):**

```swift
CommandMenu("PaperPress") { Button("Convert") { … }.keyboardShortcut("k") }
```

**Correct:**

```swift
CommandGroup(after: .newItem) {
    Button("Convert…") { model.chooseOutputAndConvert() }
        .keyboardShortcut(.return, modifiers: .command)
}
```

Reference: Apple Human Interface Guidelines, Keyboard and Menus.
