-- Tabs: Zuno's default layout pack.
-- Phase 1 only reads the color schemes; regions and form factors come with the pack loader (Phase 4).
-- Same values as docs/design/tabs-variants.html and the website.
return {
  id = "tabs",
  name = "Tabs",
  schemes = {
    light = {
      bar = "#e6e4dd", bg = "#fbfaf7", app = "#f3f2ee", line = "#e3e1da", card = "#ffffff", sunken = "#f0eee8",
      text = "#16181d", soft = "#4a4e57", muted = "#5d616b", faint = "#6b6f78",
      sel_bg = "#16181d", sel_fg = "#ffffff", accent = "#c2410c", accent_hover = "#9a3412", on_accent = "#ffffff",
      ok = "#3f6d2a", voice = "#4f7a3a", input = "#dcd9d0", media = "#e6e4dd", scrim = "#16181d59",
      online = "#16a34a", idle = "#d97706", danger = "#b91c1c", danger_bg = "#fef2f2", hover = "#16181d0d",
      names = { "#1d4ed8", "#9d174d", "#c2410c", "#0f766e", "#6d28d9", "#a16207", "#be123c", "#15803d" },
      avatars = { "#f59e0b", "#a7f3d0", "#c7d2fe", "#bfdbfe", "#fbcfe8", "#fde68a", "#ddd6fe", "#bbf7d0" },
    },
    dark = {
      bar = "#0e0f12", bg = "#17191e", app = "#121317", line = "#2a2d35", card = "#1f2228", sunken = "#23262d",
      text = "#ecebe6", soft = "#c4c6cc", muted = "#9a9ea8", faint = "#868a94",
      sel_bg = "#ecebe6", sel_fg = "#16181d", accent = "#f06a2a", accent_hover = "#ff8547", on_accent = "#16181d",
      ok = "#7fbf5c", voice = "#8fc46f", input = "#2f333b", media = "#262a31", scrim = "#0000008c",
      online = "#22c55e", idle = "#f59e0b", danger = "#f87171", danger_bg = "#3a1d1d", hover = "#ffffff0d",
      names = { "#7aa7ff", "#f27aac", "#fb8a4c", "#3fd1bd", "#b49cff", "#f2c94c", "#ff7a90", "#6fd38a" },
      avatars = { "#f59e0b", "#a7f3d0", "#c7d2fe", "#bfdbfe", "#fbcfe8", "#fde68a", "#ddd6fe", "#bbf7d0" },
    },
  },
}
