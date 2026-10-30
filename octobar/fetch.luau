--!nonstrict
-- Headless [[service]] entry — the only place that talks to GitHub.
--
-- On every tick (and on manual refresh) it runs one `gh api graphql` search
-- per configured rule, merges the results (deduped by PR url, sorted by
-- updatedAt desc), and publishes them to the plugin's shared state for the
-- bar widget and panel to render. The same query returns the reviews and
-- comments since the previous tick, which become "activity" entries and
-- desktop notifications. It also counts the commits each tracked local branch
-- is behind its GitHub counterpart. See the state contract below.
--
-- State keys published:
--   prs                array of { number, title, url, repo, author, isDraft,
--                      reviewDecision, ci, updatedAt } — nulls normalized to ""
--   counts             { total, failing, pending, approved, changes_requested, drafts }
--   activity           array of { url, prUrl, repo, number, title, kind, actor,
--                      createdAt }, newest first, until acknowledged.
--                      kind: "approved" | "changes" | "comment" | "mention" |
--                      "review_requested" | "ci_failed"
--   branches           array of { repo, branch, behind, url }
--   error_message      "" when healthy; full-failure error or partial warning
--   last_updated_text  preformatted "HH:MM" of the last successful merge
--   rules_count        number of configured rules (panel empty-state hint)
--   overflow_count     sum of matches beyond the per-rule 50 cap
--   fetch_status       "loading" | "ok" | "error" — always set LAST so watchers
--                      observe a consistent snapshot
-- State keys consumed:
--   refresh_requested  monotonic nonce bumped by the panel's refresh button
--   ack_requested      monotonic nonce bumped by the panel's "mark seen" button

local GH_TIMEOUT_MS = 30000
local DEFAULT_INTERVAL_S = 180
local MIN_INTERVAL_S = 30
local RESULTS_PER_RULE = 50
local MAX_ACTIVITY = 50
-- The next query starts this far before the current one to absorb clock skew;
-- the seen set drops the repeats.
local SINCE_OVERLAP_S = 120

-- Single line and free of single quotes, so argument quoting stays trivial.
local GRAPHQL_QUERY =
  "query($q: String!, $since: DateTime!) { viewer { login } search(query: $q, type: ISSUE, first: 50) { issueCount nodes { ... on PullRequest { number title url isDraft reviewDecision updatedAt repository { nameWithOwner } author { login } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } timelineItems(since: $since, last: 20, itemTypes: [PULL_REQUEST_REVIEW, ISSUE_COMMENT]) { nodes { __typename ... on PullRequestReview { state createdAt url bodyText author { __typename login } } ... on IssueComment { createdAt url bodyText author { __typename login } } } } } } } }"

-- Projects the response down to plain PR records and normalizes the nullable
-- fields (ghost author, no review decision, no CI checks) to "" so Luau never
-- sees nil holes. select(.url != null) drops nodes that failed the inline
-- fragment spread. .count keeps the raw issueCount for the overflow note.
-- Events drop the viewer's own actions, bots and pending/dismissed reviews;
-- comment bodies are reduced to a mention flag so stdout stays small.
local JQ_PROJECTION =
  '.data.viewer.login as $me | {count: .data.search.issueCount, viewer: $me, items: [.data.search.nodes[] | select(.url != null) | {number, title, url, isDraft, updatedAt, repo: .repository.nameWithOwner, author: (.author.login // ""), reviewDecision: (.reviewDecision // ""), ci: (.commits.nodes[0].commit.statusCheckRollup.state // ""), events: [.timelineItems.nodes[] | select(.author != null and .author.__typename != "Bot" and .author.login != $me and .state != "PENDING" and .state != "DISMISSED") | {review: (.__typename == "PullRequestReview"), state: (.state // ""), url, createdAt, actor: .author.login, mention: ((.bodyText // "") | ascii_downcase | contains("@" + ($me | ascii_downcase)))}]}]}'

-- Positional args: $1 local path, $2 branch. Prints one JSON record.
local BRANCH_SCRIPT = [[
set -e
cd "$1"
sha=$(git rev-parse "$2")
slug=$(git remote get-url origin | sed -E 's#(\.git)?/*$##; s#^.*github\.com[:/]##')
behind=$(gh api "repos/$slug/compare/$sha...$2" --jq .ahead_by)
printf '{"repo":"%s","branch":"%s","behind":%s,"url":"https://github.com/%s/compare/%s...%s"}' "$slug" "$2" "$behind" "$slug" "$sha" "$2"
]]

local fetching = false
local fetchGeneration = 0
local lastRefreshNonce = noctalia.state.get("refresh_requested") or 0
local lastAckNonce = noctalia.state.get("ack_requested") or 0
local fetchingBranches = false
-- After a rate-limit answer from GitHub, every call waits until this time (os.time()).
local RATE_LIMIT_PAUSE_S = 900
local pausedUntil = 0

local function checkRateLimit(message)
  if message and message:lower():find("rate limit", 1, true) then
    pausedUntil = os.time() + RATE_LIMIT_PAUSE_S
    noctalia.log(`octobar: GitHub rate limit hit, pausing for {RATE_LIMIT_PAUSE_S}s`)
  end
end

local function rateLimited()
  return os.time() < pausedUntil
end

local activityFile = noctalia.pluginDataDir() .. "/activity.json"
-- since: ISO timestamp the next query starts from. seen: event url -> createdAt.
local activity = { since = nil, seen = {}, events = {} }

local function quoteShellArgument(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function readRules()
  local raw = noctalia.getConfig("rules")
  local rules = {}
  if type(raw) == "table" then
    for _, rule in ipairs(raw) do
      if type(rule) == "string" then
        local trimmed = noctalia.string.trim(rule)
        if trimmed ~= "" then
          table.insert(rules, trimmed)
        end
      end
    end
  end
  return rules
end

local function readExcludedRepositories()
  local raw = noctalia.getConfig("excluded_repositories")
  local patterns = {}
  if type(raw) == "table" then
    for _, pattern in ipairs(raw) do
      if type(pattern) == "string" then
        local trimmed = noctalia.string.trim(pattern)
        if trimmed ~= "" then
          table.insert(patterns, trimmed:lower())
        end
      end
    end
  end
  return patterns
end

-- Small glob matcher: '*' consumes zero or more characters. Patterns without
-- an owner match the repository basename; patterns containing '/' match the
-- full owner/name, without relying on GitHub search's exact-only repo:
-- qualifier.
local function globMatches(value, pattern)
  local valueIndex = 1
  local patternIndex = 1
  local starIndex = nil
  local starValueIndex = nil

  while valueIndex <= #value do
    local patternChar = pattern:sub(patternIndex, patternIndex)
    if patternChar == "*" then
      starIndex = patternIndex
      starValueIndex = valueIndex
      patternIndex += 1
    elseif patternIndex <= #pattern and patternChar == value:sub(valueIndex, valueIndex) then
      valueIndex += 1
      patternIndex += 1
    elseif starIndex ~= nil then
      starValueIndex += 1
      valueIndex = starValueIndex
      patternIndex = starIndex + 1
    else
      return false
    end
  end

  while pattern:sub(patternIndex, patternIndex) == "*" do
    patternIndex += 1
  end
  return patternIndex > #pattern
end

local function repositoryExcluded(repo, patterns)
  local fullName = repo:lower()
  local basename = fullName:match("[^/]+$") or fullName
  for _, pattern in ipairs(patterns) do
    local candidate = pattern:find("/", 1, true) and fullName or basename
    if globMatches(candidate, pattern) then
      return true
    end
  end
  return false
end

local function filterExcluded(prs, patterns)
  local filtered = {}
  for _, pr in ipairs(prs) do
    if not repositoryExcluded(pr.repo, patterns) then
      table.insert(filtered, pr)
    end
  end
  return filtered
end

local function readIgnoredAuthors()
  local raw = noctalia.getConfig("ignored_authors")
  local patterns = {}
  if type(raw) == "table" then
    for _, pattern in ipairs(raw) do
      if type(pattern) == "string" then
        local trimmed = noctalia.string.trim(pattern)
        if trimmed ~= "" then
          table.insert(patterns, trimmed:lower())
        end
      end
    end
  end
  return patterns
end

local function authorIgnored(login, patterns)
  local name = login:lower()
  for _, pattern in ipairs(patterns) do
    if globMatches(name, pattern) then
      return true
    end
  end
  return false
end

local function readIntervalMs()
  local interval = tonumber(noctalia.getConfig("refresh_interval")) or DEFAULT_INTERVAL_S
  return math.max(MIN_INTERVAL_S, interval) * 1000
end

local function buildSearchQuery(rule)
  local q = "is:pr is:open"
  if not rule:find("archived:", 1, true) then
    q ..= " archived:false"
  end
  return q .. " " .. rule
end

-- Merged PRs leave the open-PR rules, so one extra search catches reviews that
-- landed right before the merge. It only feeds activity, never the PR list.
local function mergedQuery(since)
  return "is:pr is:merged author:@me merged:>=" .. since
end

local function buildCommand(query, since)
  return "gh api graphql -f query="
    .. quoteShellArgument(GRAPHQL_QUERY)
    .. " -f q="
    .. quoteShellArgument(query)
    .. " -f since="
    .. quoteShellArgument(since)
    .. " --jq "
    .. quoteShellArgument(JQ_PROJECTION)
end

local function isoTime(offsetSeconds)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + (offsetSeconds or 0))
end

local function loadActivity()
  local raw = noctalia.readFile(activityFile)
  local decoded = type(raw) == "string" and raw ~= "" and noctalia.json.decode(raw) or nil
  if type(decoded) == "table" then
    activity.since = type(decoded.since) == "string" and decoded.since or nil
    activity.seen = type(decoded.seen) == "table" and decoded.seen or {}
    activity.events = type(decoded.events) == "table" and decoded.events or {}
    -- nil until the first successful fetch, so existing state is not reported.
    activity.requested = type(decoded.requested) == "table" and decoded.requested or nil
    activity.ci = type(decoded.ci) == "table" and decoded.ci or nil
  end
end

local function saveActivity()
  noctalia.mkdirAll(noctalia.pluginDataDir())
  noctalia.writeFile(activityFile, noctalia.json.encode(activity))
end

-- Only the viewer's own PRs report reviews and comments; mentions count on any PR.
local function classifyEvent(event, pr, viewer)
  if event.mention then
    return "mention"
  end
  if pr.author ~= viewer then
    return nil
  end
  if event.state == "APPROVED" then
    return "approved"
  elseif event.state == "CHANGES_REQUESTED" then
    return "changes"
  end
  return "comment"
end

local function notifyEvent(entry)
  noctalia.notify(
    `{entry.repo}#{entry.number}`,
    noctalia.tr("activity." .. entry.kind, { actor = entry.actor }) .. "\n" .. entry.title
  )
end

local function entryFor(pr, kind, actor, url, createdAt)
  return {
    url = url,
    prUrl = pr.url,
    repo = pr.repo,
    number = pr.number,
    title = pr.title,
    kind = kind,
    actor = actor,
    createdAt = createdAt,
  }
end

-- Turns the timeline events of this tick into activity entries and strips the
-- raw events from the PR records.
local function collectEvents(ruleResults, excludedRepositories, fresh)
  local ignoredAuthors = readIgnoredAuthors()
  for _, decoded in ipairs(ruleResults) do
    for _, pr in ipairs(decoded.items) do
      local events = not repositoryExcluded(pr.repo, excludedRepositories) and pr.events or {}
      for _, event in ipairs(events) do
        if activity.seen[event.url] == nil then
          activity.seen[event.url] = event.createdAt
          local kind = not authorIgnored(event.actor, ignoredAuthors) and classifyEvent(event, pr, decoded.viewer)
          if kind then
            table.insert(fresh, entryFor(pr, kind, event.actor, event.url, event.createdAt))
          end
        end
      end
      pr.events = nil
    end
  end
end

-- Review requests and CI failures have no timeline event: they are diffs
-- against the previous tick. requestedUrls is nil when that rule failed.
local function collectChanges(prs, viewer, requestedUrls, complete, fresh)
  local now = isoTime()
  if requestedUrls then
    if activity.requested then
      for _, pr in ipairs(prs) do
        if requestedUrls[pr.url] and not activity.requested[pr.url] then
          table.insert(fresh, entryFor(pr, "review_requested", pr.author, `{pr.url}#requested-{now}`, now))
        end
      end
    end
    activity.requested = requestedUrls
  end

  local ci = complete and {} or (activity.ci or {})
  for _, pr in ipairs(prs) do
    if pr.author == viewer then
      local failing = pr.ci == "FAILURE" or pr.ci == "ERROR"
      local previous = activity.ci and activity.ci[pr.url]
      if failing and previous ~= nil and previous ~= "FAILURE" and previous ~= "ERROR" then
        table.insert(fresh, entryFor(pr, "ci_failed", "CI", `{pr.url}#ci-{now}`, now))
      end
      ci[pr.url] = pr.ci
    end
  end
  activity.ci = ci
end

local function publishActivity(fresh, nextSince)
  local notify = noctalia.getConfig("notify") ~= false
  table.sort(fresh, function(a, b)
    return a.createdAt < b.createdAt
  end)
  for _, entry in ipairs(fresh) do
    table.insert(activity.events, 1, entry)
    if notify then
      notifyEvent(entry)
    end
  end
  while #activity.events > MAX_ACTIVITY do
    table.remove(activity.events)
  end

  if nextSince then
    activity.since = nextSince
    -- Older entries can no longer come back from a query starting at since.
    for url, createdAt in pairs(activity.seen) do
      if createdAt < nextSince then
        activity.seen[url] = nil
      end
    end
  end
  saveActivity()
  noctalia.state.set("activity", activity.events)
end

local function readTrackedBranches()
  local raw = noctalia.getConfig("tracked_branches")
  local entries = {}
  if type(raw) == "table" then
    for path, branch in pairs(raw) do
      if type(path) == "string" and type(branch) == "string" and branch ~= "" then
        table.insert(entries, { path = noctalia.expandPath(path), branch = branch })
      end
    end
  end
  return entries
end

local function fetchBranches()
  if fetchingBranches or rateLimited() then
    return
  end
  local entries = readTrackedBranches()
  if #entries == 0 then
    noctalia.state.set("branches", {})
    return
  end

  fetchingBranches = true
  local results = {}
  local pending = #entries
  local function done()
    pending -= 1
    if pending == 0 then
      fetchingBranches = false
      table.sort(results, function(a, b)
        return a.repo < b.repo
      end)
      noctalia.state.set("branches", results)
    end
  end

  for _, entry in ipairs(entries) do
    local started = noctalia.runAsync({ "sh", "-c", BRANCH_SCRIPT, "sh", entry.path, entry.branch }, function(result)
      local decoded = result.exitCode == 0 and not result.timedOut and noctalia.json.decode(result.stdout or "")
      if type(decoded) == "table" then
        table.insert(results, decoded)
      else
        checkRateLimit(result.stderr)
        noctalia.log(`octobar: branch {entry.branch} in {entry.path} failed: {result.stderr or ""}`)
      end
      done()
    end, GH_TIMEOUT_MS)
    if not started then
      done()
    end
  end
end

local function computeCounts(prs)
  local counts = { total = #prs, failing = 0, pending = 0, approved = 0, changes_requested = 0, drafts = 0 }
  for _, pr in ipairs(prs) do
    if pr.ci == "FAILURE" or pr.ci == "ERROR" then
      counts.failing += 1
    elseif pr.ci == "PENDING" or pr.ci == "EXPECTED" then
      counts.pending += 1
    end
    if pr.reviewDecision == "APPROVED" then
      counts.approved += 1
    elseif pr.reviewDecision == "CHANGES_REQUESTED" then
      counts.changes_requested += 1
    end
    if pr.isDraft then
      counts.drafts += 1
    end
  end
  return counts
end

-- fetch_status last: watchers triggering on it see prs/counts already updated.
local function publish(prs, status, errorMessage, overflow, rulesCount, updateTimestamp)
  noctalia.state.set("prs", prs)
  noctalia.state.set("counts", computeCounts(prs))
  noctalia.state.set("overflow_count", overflow)
  noctalia.state.set("rules_count", rulesCount)
  if updateTimestamp then
    noctalia.state.set("last_updated_text", noctalia.formatTime("%H:%M"))
  end
  noctalia.state.set("error_message", errorMessage)
  noctalia.state.set("fetch_status", status)
end

local function classifyResult(result)
  if result.timedOut then
    return nil, noctalia.tr("error.timeout")
  end
  if result.exitCode ~= 0 then
    local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]+")
    return nil, message or `gh exited with code {result.exitCode}`
  end
  if result.stdoutTruncated then
    return nil, noctalia.tr("error.truncated")
  end
  local decoded = noctalia.json.decode(result.stdout)
  if type(decoded) ~= "table" or type(decoded.items) ~= "table" then
    return nil, noctalia.tr("error.parse")
  end
  return decoded, nil
end

local function mergeAndPublish(ruleResults, ruleErrors, rulesCount, excludedRepositories, nextSince, extraOk)
  local fresh = {}
  collectEvents(ruleResults, excludedRepositories, fresh)

  local prs = {}
  local seen = {}
  local overflow = 0
  local viewer = nil
  local requestedUrls = nil
  for _, decoded in ipairs(ruleResults) do
    viewer = viewer or decoded.viewer
    if decoded.rule and decoded.rule:find("review-requested:", 1, true) then
      requestedUrls = requestedUrls or {}
      for _, pr in ipairs(decoded.items) do
        requestedUrls[pr.url] = true
      end
    end
  end
  for _, decoded in ipairs(ruleResults) do
    for _, pr in ipairs(decoded.activityOnly and {} or decoded.items) do
      if not seen[pr.url] and not repositoryExcluded(pr.repo, excludedRepositories) then
        seen[pr.url] = true
        table.insert(prs, pr)
      end
    end
    local count = decoded.activityOnly and 0 or tonumber(decoded.count) or 0
    overflow += math.max(0, count - RESULTS_PER_RULE)
  end
  -- ISO-8601 UTC timestamps sort lexicographically; newest first.
  table.sort(prs, function(a, b)
    return a.updatedAt > b.updatedAt
  end)

  -- Keep since in place when a search failed so its events are fetched next time.
  local complete = #ruleErrors == 0 and extraOk
  collectChanges(prs, viewer, requestedUrls, complete, fresh)
  publishActivity(fresh, complete and nextSince or nil)

  if #ruleErrors >= rulesCount then
    -- Every rule failed: keep the previous (still filtered) list visible.
    local previous = filterExcluded(noctalia.state.get("prs"), excludedRepositories)
    publish(previous, "error", ruleErrors[1], noctalia.state.get("overflow_count"), rulesCount, false)
  elseif #ruleErrors > 0 then
    local warning = noctalia.tr("panel.partial_warning", {
      failed = #ruleErrors,
      total = rulesCount,
      message = ruleErrors[1],
    })
    publish(prs, "ok", warning, overflow, rulesCount, true)
  else
    publish(prs, "ok", "", overflow, rulesCount, true)
  end
end

local function startFetch()
  if fetching or rateLimited() then
    return
  end

  local rules = readRules()
  local excludedRepositories = readExcludedRepositories()
  if #rules == 0 then
    publish({}, "ok", "", 0, 0, true)
    return
  end

  if not noctalia.commandExists("gh") then
    local previous = filterExcluded(noctalia.state.get("prs"), excludedRepositories)
    publish(previous, "error", noctalia.tr("error.gh_missing"), 0, #rules, false)
    return
  end

  fetching = true
  fetchGeneration += 1
  local thisGeneration = fetchGeneration
  -- First run starts now: no notifications for what happened before install.
  local since = activity.since or isoTime()
  local nextSince = isoTime(-SINCE_OVERLAP_S)

  -- Flip to loading but keep the stale list so the UI never flashes empty.
  noctalia.state.set("error_message", "")
  noctalia.state.set("fetch_status", "loading")

  local pending = #rules + 1
  local ruleResults = {}
  local ruleErrors = {}
  local extraOk = false

  local function ruleDone()
    pending -= 1
    if pending == 0 then
      fetching = false
      mergeAndPublish(ruleResults, ruleErrors, #rules, excludedRepositories, nextSince, extraOk)
    end
  end

  local mergedStarted = noctalia.runAsync(buildCommand(mergedQuery(since), since), function(result)
    if thisGeneration ~= fetchGeneration then
      return
    end
    local decoded, err = classifyResult(result)
    if decoded then
      decoded.activityOnly = true
      table.insert(ruleResults, decoded)
      extraOk = true
    else
      checkRateLimit(err)
      noctalia.log(`octobar: merged search failed: {err}`)
    end
    ruleDone()
  end, GH_TIMEOUT_MS)
  if not mergedStarted then
    ruleDone()
  end

  for _, rule in ipairs(rules) do
    local started = noctalia.runAsync(buildCommand(buildSearchQuery(rule), since), function(result)
      if thisGeneration ~= fetchGeneration then
        return -- config changed mid-flight; a newer fetch owns the state
      end
      local decoded, err = classifyResult(result)
      if decoded then
        decoded.rule = rule
        table.insert(ruleResults, decoded)
      else
        checkRateLimit(err)
        table.insert(ruleErrors, `{rule}: {err}`)
        noctalia.log(`octobar: rule "{rule}" failed: {err}`)
      end
      ruleDone()
    end, GH_TIMEOUT_MS)

    if not started then
      table.insert(ruleErrors, `{rule}: could not start gh`)
      ruleDone()
    end
  end
end

local function restartFetch()
  -- Existing gh processes cannot be cancelled, so invalidate their callbacks
  -- before starting the replacement fetch.
  if fetching then
    fetching = false
    fetchGeneration += 1
  end
  startFetch()
end

noctalia.setUpdateInterval(readIntervalMs())

loadActivity()
noctalia.state.set("activity", activity.events)

if noctalia.state.get("fetch_status") == nil then
  noctalia.state.set("last_updated_text", "")
  publish({}, "loading", "", 0, #readRules(), false)
end

noctalia.state.watch("refresh_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce ~= lastRefreshNonce then
    lastRefreshNonce = nonce
    restartFetch()
    fetchBranches()
  end
end)

noctalia.state.watch("ack_requested", function(value)
  local nonce = tonumber(value) or 0
  if nonce ~= lastAckNonce then
    lastAckNonce = nonce
    activity.events = {}
    saveActivity()
    noctalia.state.set("activity", activity.events)
  end
end)

startFetch()
fetchBranches()

function update()
  startFetch()
  fetchBranches()
end

-- Defining this keeps the service alive across settings edits (no VM restart);
-- everything config-derived must be re-read here.
function onConfigChanged()
  noctalia.setUpdateInterval(readIntervalMs())
  restartFetch()
  fetchBranches()
end

function onIpc(event, _payload)
  if event == "refresh" then
    restartFetch()
  elseif event == "dump" then
    local summary = {
      status = noctalia.state.get("fetch_status"),
      count = #noctalia.state.get("prs"),
      error = noctalia.state.get("error_message"),
      updated = noctalia.state.get("last_updated_text"),
    }
    noctalia.log("octobar: " .. (noctalia.json.encode(summary) or "?"))
  end
end
