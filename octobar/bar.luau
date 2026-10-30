--!nonstrict
-- Bar [[widget]] entry: glyph + open-PR count, plus a bell with the unseen
-- activity count, fed entirely by the fetch service through shared state. The
-- PR glyph tints error-red when fetching itself failed and the bell when a
-- review requested changes or CI failed; details remain available in the panel.
-- Clicking anywhere on the capsule toggles the panel —
-- which is why the tree deliberately contains no inline ui.button (inline
-- controls would consume their own clicks).

local PANEL_ID = "sn4pe/octobar:panel"

local counts = noctalia.state.get("counts")
local fetchStatus = noctalia.state.get("fetch_status") or "loading"
local activity = noctalia.state.get("activity") or {}

local function countText()
  if counts ~= nil then
    return tostring(counts.total)
  end
  if fetchStatus == "error" then
    return "!"
  end
  return "…"
end

local function render()
  local hideWhenZero = noctalia.getConfig("hide_when_zero") == true
  if hideWhenZero and fetchStatus == "ok" and counts ~= nil and counts.total == 0 and #activity == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local glyph = noctalia.getConfig("glyph")
  if type(glyph) ~= "string" or glyph == "" then
    glyph = "git-pull-request"
  end
  local isVertical = barWidget.isVertical()
  local container = isVertical and ui.column or ui.row
  local layout = { gap = 4, align = "center" }
  if isVertical then
    layout.paddingV = 4
  else
    layout.paddingH = 4
  end
  local children = {
    ui.glyph({
      name = glyph,
      size = 16,
      color = fetchStatus == "error" and "error" or "on_surface",
    }),
    ui.label({
      text = countText(),
      color = "on_surface",
    }),
  }
  if #activity > 0 then
    local bellColor = "primary"
    for _, entry in ipairs(activity) do
      if entry.kind == "changes" or entry.kind == "ci_failed" then
        bellColor = "error"
        break
      end
    end
    table.insert(children, ui.glyph({ name = "bell", size = 16, color = bellColor }))
    table.insert(children, ui.label({ text = tostring(#activity), color = bellColor }))
  end
  barWidget.render(container(layout, children))
end

-- fetch_status is published last by the service, so one watcher on it sees a
-- consistent prs/counts snapshot; the counts watcher covers same-status updates.
noctalia.state.watch("counts", function(value)
  counts = value
  render()
end)

noctalia.state.watch("activity", function(value)
  activity = value or {}
  render()
end)

noctalia.state.watch("fetch_status", function(value)
  fetchStatus = value
  render()
end)

render()

function update()
  noctalia.setUpdateInterval(5000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onConfigChanged()
  render()
end
