--!nonstrict
-- [[panel]] entry: unseen activity and tracked branches that are behind on
-- top, then pull requests grouped by repository, rendered from the shared
-- state the fetch service publishes. Each pull request uses two lines so long
-- titles cannot collide with the status badges; clicking the title opens the
-- PR in the browser. Repo groups start folded unless one of their PRs needs
-- you. The header carries the last-refresh time, refresh and close.
--
local MAX_ROWS = 80
local CENTERED_LAYOUT = { flexGrow = 1, align = "center", justify = "center", gap = 8 }

local CI_APPEARANCE = {
  SUCCESS = { glyph = "circle-check", color = "primary" },
  FAILURE = { glyph = "circle-x", color = "error" },
  ERROR = { glyph = "alert-circle", color = "error" },
  PENDING = { glyph = "clock", color = "tertiary" },
  EXPECTED = { glyph = "clock", color = "tertiary" },
}
local CI_NONE = { glyph = "circle-dashed", color = "on_surface_variant" }

local ACTIVITY_GLYPH = {
  approved = { glyph = "circle-check", color = "primary" },
  changes = { glyph = "alert-circle", color = "error" },
  comment = { glyph = "message", color = "tertiary" },
  mention = { glyph = "at", color = "tertiary" },
  review_requested = { glyph = "eye", color = "tertiary" },
  ci_failed = { glyph = "circle-x", color = "error" },
}

local REVIEW_BADGE = {
  APPROVED = { key = "panel.review.approved", color = "primary" },
  CHANGES_REQUESTED = { key = "panel.review.changes_requested", color = "error" },
  PARTIALLY_APPROVED = { key = "panel.review.partial", color = "tertiary" },
  REVIEW_REQUIRED = { key = "panel.review.review_required", color = "tertiary" },
}

local REVIEW_REQUESTED_BADGE = { key = "panel.review.requested_you", color = "tertiary" }

local CARD = { fill = "surface_container/0.24", radius = 11, align = "stretch" }

local prs = {}
local activity = {}
local branches = {}
local fetchStatus = "loading"
local errorMessage = ""
local lastUpdatedText = ""
local rulesCount = nil
local overflowCount = 0
local isOpen = false
-- Explicit fold state per section; nil falls back to the section default.
-- Repo groups use "repo:<name>".
local expanded = {}

local render

local tr = noctalia.tr

local function syncFromState()
  prs = noctalia.state.get("prs")
  activity = noctalia.state.get("activity") or {}
  branches = {}
  for _, b in ipairs(noctalia.state.get("branches") or {}) do
    if b.behind > 0 then
      table.insert(branches, b)
    end
  end
  fetchStatus = noctalia.state.get("fetch_status")
  errorMessage = noctalia.state.get("error_message")
  lastUpdatedText = noctalia.state.get("last_updated_text")
  rulesCount = noctalia.state.get("rules_count")
  overflowCount = noctalia.state.get("overflow_count")

  local activeRepos = {}
  for _, pr in ipairs(prs) do
    activeRepos[pr.repo] = true
  end
  for id, _ in pairs(expanded) do
    local repo = id:match("^repo:(.+)$")
    if repo and not activeRepos[repo] then
      expanded[id] = nil
    end
  end
end

-- Pills are for states only; counters are plain labels.
local function badge(text, color, fillAlpha)
  return ui.row({ fill = `{color}/{fillAlpha}`, radius = 8, paddingH = 7, paddingV = 2, align = "center" }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "medium", color = color }),
  })
end

local function counter(n)
  return ui.label({ text = tostring(n), fontSize = 12, color = "on_surface_variant" })
end

local function openUrl(url)
  noctalia.runAsync({ "xdg-open", url })
end

local function isOpenSection(id, default)
  if expanded[id] == nil then
    return default
  end
  return expanded[id]
end

local function sectionHeader(id, open, children)
  local row = {
    ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 15, color = "on_surface_variant" }),
  }
  for _, c in ipairs(children) do
    table.insert(row, c)
  end
  return ui.row({
    key = `head:{id}`,
    gap = 8,
    align = "center",
    paddingH = 11,
    paddingV = 8,
    onClick = function()
      expanded[id] = not open
      render()
    end,
  }, row)
end

-- GitHub timestamps are UTC; os.time reads a table as local time, so add the offset back.
local function localTime(iso)
  local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return ""
  end
  local now = os.time()
  local offset = now - os.time(os.date("!*t", now))
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }) + offset
  return os.date(os.date("%Y-%m-%d", t) == os.date("%Y-%m-%d", now) and "%H:%M" or "%d/%m %H:%M", t)
end

local function needsYou(pr)
  return pr.reviewRequested
    or (pr.mine and (pr.ci == "FAILURE" or pr.ci == "ERROR" or pr.reviewDecision == "CHANGES_REQUESTED"))
end

local function activityRow(entry)
  local look = ACTIVITY_GLYPH[entry.kind] or ACTIVITY_GLYPH.comment
  local when = localTime(entry.createdAt)
  local what = tr("activity." .. entry.kind, { actor = entry.actor })
  return ui.column({ key = entry.url, gap = 2, paddingH = 10, paddingV = 6, align = "stretch" }, {
    ui.row({ gap = 9, align = "center" }, {
      ui.glyph({ name = look.glyph, size = 15, color = look.color }),
      ui.button({
        key = `open:{entry.url}`,
        text = `{entry.repo}#{entry.number} {entry.title}`,
        variant = "ghost",
        contentAlign = "start",
        flexGrow = 1,
        onClick = function()
          openUrl(entry.url)
          noctalia.state.set("ack_url", entry.url)
        end,
      }),
    }),
    ui.row({ paddingH = 24 }, {
      ui.label({ text = when ~= "" and `{what} · {when}` or what, fontSize = 11, color = "on_surface_variant" }),
    }),
  })
end

local function activitySection()
  local open = isOpenSection("activity", true)
  local children = {
    sectionHeader("activity", open, {
      ui.glyph({ name = "bell", size = 16, color = "primary" }),
      ui.label({ text = tr("panel.activity"), fontSize = 13, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      counter(#activity),
    }),
  }
  if open then
    for _, entry in ipairs(activity) do
      table.insert(children, activityRow(entry))
    end
    table.insert(children, ui.row({ paddingH = 6, paddingV = 4 }, {
      ui.button({
        text = tr("panel.mark_seen"),
        variant = "ghost",
        onClick = function()
          noctalia.state.set("ack_requested", (noctalia.state.get("ack_requested") or 0) + 1)
        end,
      }),
    }))
  end
  return ui.column({ key = "activity", fill = CARD.fill, radius = CARD.radius, align = CARD.align }, children)
end

local function branchesSection()
  local open = isOpenSection("branches", false)
  local children = {
    sectionHeader("branches", open, {
      ui.glyph({ name = "git-branch", size = 16, color = "on_surface" }),
      ui.label({ text = tr("panel.branches"), fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      counter(#branches),
    }),
  }
  for _, b in ipairs(open and branches or {}) do
    table.insert(children, ui.row({ key = `branch:{b.repo}:{b.branch}`, gap = 8, align = "center", paddingH = 11, paddingV = 6 }, {
      ui.label({ text = `{b.repo} {b.branch}`, fontSize = 12, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.label({ text = `+{b.behind}`, fontSize = 12, color = "on_surface_variant" }),
      ui.button({
        text = tr("panel.compare"),
        variant = "ghost",
        onClick = function()
          openUrl(b.url)
        end,
      }),
    }))
    for _, c in ipairs(b.commits or {}) do
      table.insert(children, ui.column({ key = c.url, gap = 2, paddingH = 10, paddingV = 2, align = "stretch" }, {
        ui.button({
          text = c.message,
          variant = "ghost",
          contentAlign = "start",
          onClick = function()
            openUrl(c.url)
          end,
        }),
        ui.row({ paddingH = 12 }, {
          ui.label({ text = `{c.sha} · {c.author}`, fontSize = 11, color = "on_surface_variant" }),
        }),
      }))
    end
  end
  return ui.column({ key = "branches", fill = CARD.fill, radius = CARD.radius, align = CARD.align }, children)
end

local function prRow(pr)
  local ci = CI_APPEARANCE[pr.ci] or CI_NONE

  -- Own PRs skip the author: with author:@me it would repeat on every row.
  local statusChildren = {}
  if not pr.mine then
    table.insert(statusChildren, ui.glyph({ name = "user", size = 13, color = "on_surface_variant" }))
  end
  table.insert(statusChildren, ui.label({
    text = pr.mine and "" or pr.author,
    fontSize = 11,
    color = "on_surface_variant",
    flexGrow = 1,
    maxLines = 1,
  }))
  table.insert(statusChildren, ui.glyph({ name = ci.glyph, size = 16, color = ci.color }))
  if pr.isDraft then
    table.insert(statusChildren, badge(tr("panel.draft"), "on_surface_variant", "0.15"))
  end
  local review = pr.reviewRequested and REVIEW_REQUESTED_BADGE or REVIEW_BADGE[pr.reviewDecision]
  if review then
    table.insert(statusChildren, badge(tr(review.key, { approved = pr.approvals, total = pr.reviewers }), review.color, "0.2"))
  end

  return ui.column({ key = pr.url, gap = 4, paddingH = 10, paddingV = 7, align = "stretch" }, {
    ui.row({ gap = 9, align = "center" }, {
      ui.glyph({ name = "git-pull-request", size = 15, color = "primary" }),
      ui.button({
        key = `open:{pr.url}`,
        text = `#{pr.number} {pr.title}`,
        variant = "ghost",
        contentAlign = "start",
        flexGrow = 1,
        onClick = function()
          openUrl(pr.url)
        end,
      }),
    }),
    ui.row({ gap = 7, align = "center", paddingH = 24 }, statusChildren),
  })
end

-- One small glyph per PR state worth seeing while the group is folded.
local function alertGlyphs(list)
  local glyphs = {}
  for _, pr in ipairs(list) do
    local look = nil
    if pr.mine and (pr.ci == "FAILURE" or pr.ci == "ERROR") then
      look = ACTIVITY_GLYPH.ci_failed
    elseif pr.mine and pr.reviewDecision == "CHANGES_REQUESTED" then
      look = ACTIVITY_GLYPH.changes
    elseif pr.reviewRequested then
      look = ACTIVITY_GLYPH.review_requested
    elseif pr.mine and pr.reviewDecision == "APPROVED" then
      look = ACTIVITY_GLYPH.approved
    end
    if look then
      table.insert(glyphs, ui.glyph({ name = look.glyph, size = 14, color = look.color }))
    end
  end
  return glyphs
end

-- Group by repo and order groups by their newest PR activity. prs is globally
-- sorted by updatedAt desc, so appending in order also keeps each group recent.
local function groupedRows()
  local byRepo = {}
  local repoNames = {}
  for _, pr in ipairs(prs) do
    if byRepo[pr.repo] == nil then
      byRepo[pr.repo] = {}
      table.insert(repoNames, pr.repo)
    end
    table.insert(byRepo[pr.repo], pr)
  end

  local rows = {}
  local shown = 0
  local hiddenByCollapse = 0
  for _, repo in ipairs(repoNames) do
    if shown >= MAX_ROWS then
      break
    end
    local list = byRepo[repo]
    local urgent = false
    for _, pr in ipairs(list) do
      urgent = urgent or needsYou(pr)
    end
    local open = isOpenSection(`repo:{repo}`, urgent)
    local header = {
      ui.glyph({ name = "books", size = 16, color = "on_surface" }),
      ui.label({ text = repo, fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    }
    if not open then
      for _, g in ipairs(alertGlyphs(list)) do
        table.insert(header, g)
      end
    end
    table.insert(header, counter(#list))
    local groupChildren = { sectionHeader(`repo:{repo}`, open, header) }
    if open then
      for _, pr in ipairs(list) do
        if shown >= MAX_ROWS then
          break
        end
        table.insert(groupChildren, prRow(pr))
        shown += 1
      end
    else
      hiddenByCollapse += #list
    end
    table.insert(rows, ui.column({ key = `repo-group:{repo}`, fill = CARD.fill, radius = CARD.radius, align = CARD.align }, groupChildren))
  end

  local omitted = #prs - shown - hiddenByCollapse
  if omitted > 0 then
    table.insert(rows, ui.label({
      key = "more_rows",
      text = tr("panel.more_rows", { count = omitted }),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end
  if overflowCount > 0 then
    table.insert(rows, ui.label({
      key = "truncated_note",
      text = tr("panel.truncated_note", { count = overflowCount }),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end
  return rows
end

local function body()
  if #prs == 0 and #activity == 0 and #branches == 0 then
    if fetchStatus == "loading" then
      return ui.column(CENTERED_LAYOUT, {
        ui.label({ text = tr("panel.loading"), color = "on_surface_variant" }),
      })
    end
    if fetchStatus == "error" then
      return ui.column(CENTERED_LAYOUT, {
        ui.label({ text = tr("panel.error_title"), fontWeight = "bold", color = "error" }),
        ui.label({ text = errorMessage, color = "on_surface_variant", maxLines = 4, textAlign = "center" }),
        ui.button({
          text = tr("panel.retry"),
          variant = "primary",
          onClick = function()
            noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
          end,
        }),
      })
    end
    local emptyKey = rulesCount == 0 and "panel.empty_no_rules" or "panel.empty"
    return ui.column(CENTERED_LAYOUT, {
      ui.label({ text = tr(emptyKey), color = "on_surface_variant", textAlign = "center" }),
    })
  end
  local rows = groupedRows()
  if #branches > 0 then
    table.insert(rows, 1, branchesSection())
  end
  if #activity > 0 then
    table.insert(rows, 1, activitySection())
  end
  return ui.scroll({ flexGrow = 1, gap = 10, align = "stretch" }, rows)
end

render = function()
  if not isOpen then
    return
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
        ui.glyph({ name = "brand-github", size = 20, color = "primary" }),
        ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        counter(#prs),
      }),
      ui.label({
        text = lastUpdatedText ~= "" and tr("panel.updated_at", { time = lastUpdatedText }) or "",
        fontSize = 11,
        color = fetchStatus == "error" and "error" or "on_surface_variant",
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        enabled = fetchStatus ~= "loading",
        onClick = function()
          noctalia.state.set("refresh_requested", (noctalia.state.get("refresh_requested") or 0) + 1)
        end,
      }),
      ui.button({ glyph = "close", variant = "ghost", onClick = panel.close }),
    }),
  }

  -- Partial rule failure: data is fresh but incomplete, warn without blocking.
  if errorMessage ~= "" and fetchStatus ~= "error" then
    table.insert(children, ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 2 }))
  end

  table.insert(children, body())

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

noctalia.state.watch("fetch_status", function()
  syncFromState()
  render()
end)

noctalia.state.watch("branches", function()
  syncFromState()
  render()
end)

-- Marking activity as seen changes it without a new fetch.
noctalia.state.watch("activity", function()
  syncFromState()
  render()
end)

function onOpen(_context)
  syncFromState()
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end
