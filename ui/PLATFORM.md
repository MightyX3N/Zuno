# Platform API

The shared Lua UI (`ui/zuno_ui/`) never calls LÖVE or the browser directly. It talks to a
platform object `P` that each backend implements. Today there is one backend:
`client/zuno_native/love_backend.lua`. The browser backend (canvas + HTML inputs) will
implement the same functions.

Colors are `{r, g, b, a}` with values from 0 to 1. Coordinates are in UI units
(DPI-independent pixels).

## Drawing

| Function | What it does |
|---|---|
| `P.rect(x, y, w, h, color, radius)` | Filled rectangle, optional corner radius |
| `P.rect_line(x, y, w, h, color, radius, width)` | Rectangle outline |
| `P.circle(x, y, r, color)` / `P.circle_line(x, y, r, color, width)` | Circles |
| `P.line(points, color, width)` | Polyline, `points = {x1, y1, x2, y2, ...}` |
| `P.font(face, size)` | Font handle. Faces: `regular`, `medium`, `semibold`, `bold`, `head`, `head_bold` |
| `P.text(str, x, y, font, color)` | Single line of text |
| `P.measure(font, str)` | Width of a string |
| `P.line_height(font)` | Height of one line |
| `P.wrap(font, str, width)` | List of lines that fit in `width` |
| `P.clip(x, y, w, h)` / `P.unclip()` | Nested clipping |
| `P.image(path)` | Image handle (cached), or nil if it can't be loaded |
| `P.draw_image(img, x, y, w, h, sx, sy, sw, sh)` | Draw a part of an image (`sx..sh` in image pixels) into a box; used for the emoji sheet |
| `P.draw_image_round(img, x, y, w, h, radius, ...)` | Same, cut to a rounded rectangle (`radius = w/2` makes a circle: avatars) |
| `P.image_from_data(key, data)` | Image from file bytes, cached under `key` (attachments, avatars, server emoji). Without `data` it only looks in the cache. Nil if the bytes aren't an image |
| `P.image_size(img)` | Width and height in pixels |
| `P.image_info(data, name)` | Width and height of image bytes, or nil if they aren't an image |
| `P.square_png(data, size)` | Center-cropped square PNG of `size` pixels from image bytes (avatars, server emoji) |

Font faces also include `italic`, `bold_italic` and `mono` (message formatting).

## Input (backend → UI)

The backend forwards events to the UI: `ui:mouse_moved(x, y)`, `ui:mouse_pressed(x, y, button)`,
`ui:mouse_released(x, y, button)`, `ui:wheel(dx, dy)`, `ui:key(key, mods)`, `ui:text_input(text)`,
`ui:resize(w, h)`. Key names follow LÖVE (`return`, `escape`, `up`, `tab`, …).

## Text fields

Real editable text fields are owned by the backend (in the browser they are `<input>` /
`<textarea>` elements placed over the canvas, which gives the phone keyboard, IME and paste).

`f = P.field(id, opts)` returns (and keeps) a field. `opts`: `multiline`, `placeholder`,
`max_chars`, `secret`. Each frame the UI calls:

| Method | |
|---|---|
| `f:layout(x, y, w, font, color, placeholder_color)` | Place it this frame (height comes from the content) |
| `f:height(w)` | Height the text needs at width `w` (for growing composers) |
| `f:draw()` | Draw it (LÖVE); no-op in the browser |
| `f:get()` / `f:set(text)` | Read / replace the text |
| `f:focus()` / `f:blur()` / `f:focused()` | Keyboard focus |
| `f:set_secret(on)` | Show dots instead of the text (streamer mode, passwords) |
| `f:cursor_pos()` / `f:set_cursor(pos)` | Cursor as a byte offset (0 = before the first character) |
| `f:replace(a, b, text)` / `f:insert(text)` | Replace bytes `a+1..b` / insert at the cursor (mention and emoji suggestions) |
| `f.on_submit`, `f.on_key`, `f.on_change` | Callbacks set by the UI |

## Everything else

| Function | |
|---|---|
| `P.now()` | Seconds (float) |
| `P.size()` | Window size |
| `P.set_cursor(kind)` | `arrow`, `hand`, `ibeam` |
| `P.set_clipboard(text)` | Copy (reading only happens through a user paste into a field) |
| `P.open_url(url)` | Open a link (the UI asks the user first) |
| `P.device()` | `{ form = "desktop" \| "phone" \| "tablet" \| "tv", input = "mouse" \| "touch" \| "remote", dark = bool \| nil }` |
| `P.safe_area()` | Insets `{top, right, bottom, left}` for notches, keyboards and TV overscan |
| `P.save_file(name, data, label, ext, done)` | System "Save as" dialog. Later calls `done(path)` or `done(nil, "cancelled" \| "unavailable" \| error)` |
| `P.pick_file(label, ext, done)` | System "Open" dialog. Later calls `done(data, path)` or `done(nil, reason)` |
| `P.pick_path(label, done)` | "Open" dialog that only returns the path: `done(path, size)` or `done(nil, reason)`. For direct transfers, which stream big files instead of loading them |
| `P.open_file(path, mode)` | Streaming file handle (`"rb"`, `"wb"`, `"ab"`, `"r+b"`): `h:read(n)`, `h:write(s)`, `h:seek(pos)`, `h:size()`, `h:close()`. Unicode paths and files over 2 GB work on Windows |
| `P.file_size(path)` / `P.rename_file(a, b)` / `P.remove_file(path)` | Plain file operations on real paths |
| `P.downloads_dir()` / `P.path_sep` | The user's Downloads folder (received transfers go there) and `\` or `/` |
| `P.udp()` | Non-blocking UDP socket for direct transfers: `u.port`, `u:send(ip, port, data)`, `u:receive()` → `data, ip, port`, `u:local_ip(towards_ip)`, `u:close()`. Nil where UDP isn't possible (the browser uses WebRTC later) |
| `P.save_fallback(name, data)` | Save into Zuno's own folder when there's no dialog. Returns the path |
| `P.open_folder(path)` | Show a folder in the file manager |
| `P.recording_detected()` | True while OBS / Streamlabs runs (streamer mode "Auto"); optional |
| `P.window_focused()` | Is Zuno the active window? (decides system notification vs. in-app toast) |
| `P.notify(title, body)` | System notification; optional |
| `P.attention()` | Flash the taskbar entry / bounce the dock icon; optional |
| `P.play_sound(name)` | Short notification sound; optional |

Dropped files reach the UI through `app:file_dropped(name, data)`.
