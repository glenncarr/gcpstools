function Get-SlackChannelHistory {
<#
.SYNOPSIS
    Retrieves the last month of your daily standup entries from the
    `se-daily-standups` channel in the ConnectShip Slack workspace.

.DESCRIPTION
    Uses the Slack Web API to:
      1. Resolve the channel ID for `se-daily-standups`.
      2. Resolve the Slack user ID for the specified display / real name.
      3. Pull the channel history for the last month and keep only the
         messages authored by that user.

    Authentication is via a Slack user or bot token. The token must have at
    least the following scopes:
      - channels:read      (public channels)  or  groups:read (private)
      - channels:history   (public channels)  or  groups:history (private)
      - users:read         (to resolve the user by name)

    Provide the token via the -Token parameter or the SLACK_TOKEN environment
    variable. Never hard-code the token in the script or commit it to source
    control.

    For shared use, each user should create and install their own Slack app at
    https://api.slack.com/apps. Add the scopes listed above under Bot Token
    Scopes, install the app to the workspace, and use the resulting xoxb- bot
    token. Invite that app to each private channel it should read. As an
    alternative, install the app with the same scopes under User Token Scopes
    and use the resulting xoxp- token; it can read private channels where that
    user is a member. Do not share personal tokens, app-level xapp- tokens, or
    signing secrets with other users.

.PARAMETER Token
    Slack API token (xoxp-... user token or xoxb-... bot token). Defaults to
    the SLACK_TOKEN environment variable.

.PARAMETER Channel
    The channel name (without the leading #). Defaults to `se-daily-standups`.

.PARAMETER Username
    One or more display names or real names of the authors to include. If
    omitted, every author who posted during the period is listed. This
    parameter supports tab completion, offering the members of the -Channel
    that has been supplied (or the default channel). Completion requires a
    valid token via -Token or the SLACK_TOKEN environment variable.

.PARAMETER GroupBy
    How to group the rendered output: 'Date' (default) or 'Username'. The
    other field becomes the second-level grouping.

.PARAMETER Months
    How many months back to retrieve. Defaults to 1. Ignored when -StartDate is
    supplied.

.PARAMETER StartDate
    Inclusive start of the range. Retrieve entries posted on or after this
    date/time instead of using -Months. Accepts any value PowerShell can parse
    as a date (e.g. '2026-06-01').

.PARAMETER EndDate
    Inclusive end of the range. Retrieve entries posted on or before this
    date/time. When a bare date is given (no time component) the whole day is
    included. Defaults to the current time.

.PARAMETER AsJson
    Emit the results as JSON instead of PowerShell objects.

.EXAMPLE
    $env:SLACK_TOKEN = 'xoxp-...'
    Get-SlackChannelHistory

.EXAMPLE
    Get-SlackChannelHistory -StartDate '2026-06-01' -EndDate '2026-06-30'

.EXAMPLE
    Get-SlackChannelHistory -Username 'Glenn Carr','Zhimei Liang' -GroupBy Username -AsMarkdown
#>
[CmdletBinding()]
param(
    [string]$Token = $env:SLACK_TOKEN,
    [string]$Channel = 'se-daily-standups',
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        # This completer runs before the script body, so it cannot use the
        # script's own functions - it must be entirely self-contained. It reads
        # the token/channel the user has already typed (falling back to the same
        # defaults as the script) and offers the members of that channel.
        $token = if ($fakeBoundParameters.ContainsKey('Token')) { $fakeBoundParameters['Token'] } else { $env:SLACK_TOKEN }
        if ([string]::IsNullOrWhiteSpace($token)) { return }
        $channel = if ($fakeBoundParameters.ContainsKey('Channel')) { $fakeBoundParameters['Channel'] } else { 'se-daily-standups' }

        # Cache resolved names per channel for the session so repeated tab
        # presses do not re-hit the Slack API.
        if (-not $global:SeStandupMemberCache) { $global:SeStandupMemberCache = @{} }
        $names = $global:SeStandupMemberCache[$channel]

        if (-not $names) {
            try {
                $headers = @{ Authorization = "Bearer $token" }
                $api = 'https://slack.com/api'
                $invoke = {
                    param($method, $body)
                    Invoke-RestMethod -Uri "$api/$method" -Method Post -Headers $headers `
                        -ContentType 'application/x-www-form-urlencoded' -Body $body
                }

                # 1. Resolve the channel id by name.
                $channelId = $null
                $cursor = ''
                do {
                    $b = @{ types = 'public_channel,private_channel'; limit = 1000; exclude_archived = 'true' }
                    if ($cursor) { $b['cursor'] = $cursor }
                    $r = & $invoke 'conversations.list' $b
                    if (-not $r.ok) { return }
                    $match = $r.channels | Where-Object { $_.name -eq $channel }
                    if ($match) { $channelId = $match.id; break }
                    $cursor = $r.response_metadata.next_cursor
                } while ($cursor)
                if (-not $channelId) { return }

                # 2. Collect the member ids belonging to that channel.
                $memberIds = [System.Collections.Generic.HashSet[string]]::new()
                $cursor = ''
                do {
                    $b = @{ channel = $channelId; limit = 1000 }
                    if ($cursor) { $b['cursor'] = $cursor }
                    $r = & $invoke 'conversations.members' $b
                    if (-not $r.ok) { return }
                    foreach ($id in $r.members) { [void]$memberIds.Add($id) }
                    $cursor = $r.response_metadata.next_cursor
                } while ($cursor)

                # 3. Map those ids to human-readable names.
                $collected = [System.Collections.Generic.List[string]]::new()
                $cursor = ''
                do {
                    $b = @{ limit = 1000 }
                    if ($cursor) { $b['cursor'] = $cursor }
                    $r = & $invoke 'users.list' $b
                    if (-not $r.ok) { return }
                    foreach ($u in $r.members) {
                        if (-not $memberIds.Contains($u.id)) { continue }
                        $prof = $u.profile
                        $name = @($prof.real_name, $u.real_name, $prof.display_name, $u.name) |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                            Select-Object -First 1
                        if ($name) { $collected.Add($name) }
                    }
                    $cursor = $r.response_metadata.next_cursor
                } while ($cursor)

                $names = @($collected | Sort-Object -Unique)
                $global:SeStandupMemberCache[$channel] = $names
            }
            catch { return }
        }

        # Strip any quote the user has already typed before matching.
        $word = $wordToComplete.Trim("'`"")
        $names |
            Where-Object { $_ -like "*$word*" } |
            ForEach-Object {
                # Names contain spaces, so return a single-quoted completion.
                $quoted = "'" + ($_ -replace "'", "''") + "'"
                [System.Management.Automation.CompletionResult]::new($quoted, $_, 'ParameterValue', $_)
            }
    })]
    [string[]]$Username,
    [ValidateSet('Username', 'Date')]
    [string]$GroupBy = 'Date',
    [int]$Months = 1,
    [Nullable[datetime]]$StartDate,
    [Nullable[datetime]]$EndDate,
    [switch]$AsJson,
    [switch]$AsMarkdown,
    [switch]$UseBrowser,
    [switch]$ExcludeThreadReplies
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "No Slack token supplied. Pass -Token or set the SLACK_TOKEN environment variable."
}

if ($null -ne $StartDate -and $null -ne $EndDate -and [datetime]$EndDate -lt [datetime]$StartDate) {
    throw "EndDate ($EndDate) must be on or after StartDate ($StartDate)."
}

$SlackApiBase = 'https://slack.com/api'

function Invoke-SlackApi {
    <#
        Calls a Slack Web API method and returns the parsed response,
        throwing on any Slack-level error (ok = false).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Body = @{}
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $uri = "$SlackApiBase/$Method"

    # Slack Web API accepts form-encoded parameters.
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
        -ContentType 'application/x-www-form-urlencoded' -Body $Body

    if (-not $response.ok) {
        throw "Slack API '$Method' failed: $($response.error)"
    }

    # Respect Slack rate limiting hints when present.
    return $response
}

function Resolve-ChannelId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $cursor = ''
    do {
        $body = @{
            types             = 'public_channel,private_channel'
            limit             = 1000
            exclude_archived  = 'true'
        }
        if ($cursor) { $body['cursor'] = $cursor }

        $result = Invoke-SlackApi -Method 'conversations.list' -Body $body

        $match = $result.channels | Where-Object { $_.name -eq $Name }
        if ($match) { return $match.id }

        $cursor = $result.response_metadata.next_cursor
    } while ($cursor)

    throw "Channel '#$Name' was not found (is the token a member / does it have access?)."
}

function Get-SlackUsers {
    <#
        Returns every member of the Slack workspace, following pagination.
    #>
    [CmdletBinding()]
    param()

    $members = [System.Collections.Generic.List[object]]::new()
    $cursor = ''
    do {
        $body = @{ limit = 1000 }
        if ($cursor) { $body['cursor'] = $cursor }

        $result = Invoke-SlackApi -Method 'users.list' -Body $body
        foreach ($u in $result.members) { $members.Add($u) }

        $cursor = if ($result.PSObject.Properties['response_metadata']) {
            $result.response_metadata.next_cursor
        } else { '' }
    } while ($cursor)

    return $members
}

function Get-UserDisplayName {
    <#
        Picks the best human-readable name for a Slack member, preferring the
        real name and falling back to the display name, handle, then user ID.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Member)

    $profile     = if ($Member.PSObject.Properties['profile']) { $Member.profile } else { $null }
    $realName    = if ($Member.PSObject.Properties['real_name']) { $Member.real_name } else { $null }
    $profReal    = if ($profile -and $profile.PSObject.Properties['real_name']) { $profile.real_name } else { $null }
    $profDisplay = if ($profile -and $profile.PSObject.Properties['display_name']) { $profile.display_name } else { $null }
    $handle      = if ($Member.PSObject.Properties['name']) { $Member.name } else { $null }

    foreach ($n in @($profReal, $realName, $profDisplay, $handle)) {
        if (-not [string]::IsNullOrWhiteSpace($n)) { return $n }
    }
    return $Member.id
}

function Get-ChannelHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][double]$OldestUnix,
        [Nullable[double]]$LatestUnix
    )

    $messages = [System.Collections.Generic.List[object]]::new()
    $cursor = ''
    do {
        $body = @{
            channel = $ChannelId
            oldest  = $OldestUnix
            limit   = 200
            inclusive = 'true'
        }
        if ($null -ne $LatestUnix) { $body['latest'] = $LatestUnix }
        if ($cursor) { $body['cursor'] = $cursor }

        $result = Invoke-SlackApi -Method 'conversations.history' -Body $body
        foreach ($m in $result.messages) { $messages.Add($m) }

        $cursor = if ($result.PSObject.Properties['response_metadata']) {
            $result.response_metadata.next_cursor
        } else { '' }
    } while ($cursor)

    return $messages
}

function Get-ThreadReplies {
    <#
        Fetches all replies for a single thread (identified by the parent's
        thread timestamp), following pagination. The first element returned by
        Slack is the parent message itself, which is excluded here so only the
        actual replies are returned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][string]$ThreadTs,
        [Parameter(Mandatory)][double]$OldestUnix,
        [Nullable[double]]$LatestUnix
    )

    $replies = [System.Collections.Generic.List[object]]::new()
    $cursor = ''
    do {
        $body = @{
            channel = $ChannelId
            ts      = $ThreadTs
            limit   = 200
        }
        if ($cursor) { $body['cursor'] = $cursor }

        $result = Invoke-SlackApi -Method 'conversations.replies' -Body $body
        foreach ($m in $result.messages) {
            # Skip the parent message; keep only replies within the window.
            if ($m.ts -ne $ThreadTs -and [double]$m.ts -ge $OldestUnix -and
                ($null -eq $LatestUnix -or [double]$m.ts -le $LatestUnix)) {
                $replies.Add($m)
            }
        }

        $cursor = if ($result.PSObject.Properties['response_metadata']) {
            $result.response_metadata.next_cursor
        } else { '' }
    } while ($cursor)

    return $replies
}

function ConvertFrom-SlackMarkup {
    <#
        Converts Slack's 'mrkdwn' formatting into standard Markdown that renders
        safely in the terminal. Markdig's VT100 (terminal) renderer used by
        Show-Markdown cannot render *nested* inline formatting - a link or
        italic inside bold, bold-italic (*_x_* / ***x***), etc. It either prints
        the inline type name (e.g. 'Markdig.Syntax.Inlines.EmphasisInline') or
        silently truncates the line. HTML entities (&amp; &lt; ...) fail the
        same way.

        To guarantee safe output this flattens all inline styling to at most a
        single level:
          - Links/mentions (<url|label>, <@USER>, <#C|name>, <!here>) become
            plain label text (no Markdown link inline).
          - All HTML entities are decoded and stray angle brackets neutralised.
          - Italic ('_x_') and strike ('~x~') markers are stripped (text kept).
          - Bold-italic ('***x***') and Slack bold ('*x*') collapse to a single
            level of Markdown strong ('**x**'), which - now containing only
            plain text - renders correctly.
    #>
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    # 1. Links and mentions of the form <...> become plain text so they can
    #    never appear as a link inline nested inside emphasis. Slack always
    #    uses real angle brackets here, so handle them before decoding entities.
    $Text = [regex]::Replace($Text, '<(?<inner>[^>\n]+)>', {
        param($mm)
        $inner = $mm.Groups['inner'].Value
        if ($inner -match '\|') { $url, $label = $inner -split '\|', 2 } else { $url = $inner; $label = $null }
        switch -regex ($url) {
            '^@' { if ($label) { return '@' + $label } else { return '@' + $url.TrimStart('@') } }  # user mention
            '^#' { if ($label) { return '#' + $label } else { return '#' + $url.TrimStart('#') } }  # channel mention
            '^!' { return '@' + $url.TrimStart('!') }                                               # here/channel/everyone
            default { if ($label) { return $label } else { return $url } }                           # hyperlink -> label
        }
    })

    # 2. Decode every HTML entity Slack escapes, normalise non-breaking spaces
    #    and neutralise any remaining angle brackets so they cannot form
    #    (unrenderable) HTML inlines.
    $Text = [System.Net.WebUtility]::HtmlDecode($Text)
    $Text = $Text -replace ([char]0x00A0), ' '
    $Text = $Text -replace '<', '\<' -replace '>', '\>'

    # 3. Strip Slack italic and strike-through markers, keeping the text. This
    #    removes emphasis that would otherwise nest inside bold. Word-internal
    #    underscores (e.g. work_item) are left untouched by the boundaries.
    $Text = [regex]::Replace($Text, '(?<![_\w])_(?=\S)(?<i>[^_\n]+?)(?<=\S)_(?![_\w])', '${i}')
    $Text = [regex]::Replace($Text, '(?<![~\w])~(?=\S)(?<s>[^~\n]+?)(?<=\S)~(?![~\w])', '${s}')

    # 4. Collapse bold-italic ('***x***') then convert Slack bold ('*x*') to
    #    Markdown strong ('**x**'). By now bold spans hold only plain text, so
    #    the result is single-level strong which renders safely. The asterisk
    #    match hugs non-space text so arithmetic like 'a * b' is left alone.
    $Text = [regex]::Replace($Text, '\*\*\*(?=\S)(?<x>[^*\n]+?)(?<=\S)\*\*\*', '**${x}**')
    $Text = [regex]::Replace($Text, '(?<![\*\w])\*(?=\S)(?<b>[^*\n]+?)(?<=\S)\*(?![\*\w])', '**${b}**')

    return $Text
}

function Get-StandupItems {
    <#
        Parses a Slack message body into an ordered list of structured items so
        both the Markdown (terminal) and HTML (browser) renderers work from the
        same classification. Each item is: @{ Kind; Level; Text } where Kind is
        one of 'question', 'list', 'text', or 'blank'.

        Slack standups mix several marker styles:
          - Numbered questions ("1.") that repeat -> Kind 'question'.
          - Lettered ("a.") / roman ("ii.") answers -> Kind 'list', label kept
            in the text.
          - Bullet glyphs (U+2022 '•', U+25E6 '◦', U+25AA '▪') -> Kind 'list'.
        Nesting levels are clamped so a child is never more than one level
        deeper than its parent.
    #>
    [CmdletBinding()]
    param([string]$Text)

    # Normalise Slack markup (entities, links, bold) up front.
    $Text = ConvertFrom-SlackMarkup -Text $Text

    $bulletClass = '\u2022\u25E6\u25AA\u25AB\u2023\u2043\u2219\u00B7\u25CF'
    $glyphLevel = @{
        ([char]0x2022) = 0   # • level 1
        ([char]0x25E6) = 1   # ◦ level 2
        ([char]0x25AA) = 2   # ▪ level 3
        ([char]0x25AB) = 2   # ▫ level 3
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $prevType = 'blank'    # 'list', 'text', or 'blank'
    $lastListLevel = -1    # nesting level of the previous list item

    foreach ($raw in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $items.Add([pscustomobject]@{ Kind = 'blank'; Level = 0; Text = '' })
            $prevType = 'blank'
            $lastListLevel = -1
            continue
        }

        # Expand tabs so indentation can be measured consistently.
        $line = $raw -replace "`t", '    '
        $m = [regex]::Match($line, '^(?<indent>[ ]*)(?<body>.*)$')
        $indent = $m.Groups['indent'].Value
        $body = $m.Groups['body'].Value
        $indentLevel = [int][math]::Floor($indent.Length / 4)

        $glyph   = [regex]::Match($body, "^(?<glyph>[$bulletClass*\-])[ ]+(?<rest>.*)$")
        $number  = [regex]::Match($body, '^(?<num>\d+)(?<sep>[.)])[ ]+(?<rest>.*)$')
        $lettered = [regex]::Match($body, '^(?<let>[a-z])(?<sep>[.)])[ ]+(?<rest>.*)$')
        # Multi-character roman numerals (ii, iii, iv, ...) used for deeper
        # sub-items. Single letters (incl. i/v/x) are handled by $lettered.
        $roman = [regex]::Match($body, '^(?<rom>[ivxlcdm]{2,})(?<sep>[.)])[ ]+(?<rest>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        # Top-level numbered items are the recurring questions.
        if ($number.Success -and $indentLevel -eq 0) {
            $items.Add([pscustomobject]@{
                Kind  = 'question'
                Level = 0
                Text  = "$($number.Groups['num'].Value)$($number.Groups['sep'].Value) $($number.Groups['rest'].Value)"
            })
            $prevType = 'text'
            $lastListLevel = -1
            continue
        }

        # Determine whether this line is a list item and its content/level.
        $isList = $false
        $content = $null
        $desiredLevel = $indentLevel

        if ($glyph.Success) {
            $isList = $true
            $content = $glyph.Groups['rest'].Value
            $g = $glyph.Groups['glyph'].Value
            if ($glyphLevel.ContainsKey([char]$g)) {
                $desiredLevel = [math]::Max($indentLevel, $glyphLevel[[char]$g])
            }
        }
        elseif ($lettered.Success) {
            # Keep the letter as a visible label (e.g. "a. text").
            $isList = $true
            $content = "$($lettered.Groups['let'].Value)$($lettered.Groups['sep'].Value) $($lettered.Groups['rest'].Value)"
        }
        elseif ($roman.Success) {
            # Keep the roman numeral as a visible label (e.g. "ii. text").
            # Roman numerals are always deep sub-items; when the author typed
            # them without indentation, keep them at the current depth instead
            # of collapsing to the top level.
            $isList = $true
            $content = "$($roman.Groups['rom'].Value)$($roman.Groups['sep'].Value) $($roman.Groups['rest'].Value)"
            if ($lastListLevel -ge 0) {
                $desiredLevel = [math]::Max($indentLevel, $lastListLevel)
            }
        }
        elseif ($number.Success) {
            # Indented numbered item: keep the number as a label.
            $isList = $true
            $content = "$($number.Groups['num'].Value)$($number.Groups['sep'].Value) $($number.Groups['rest'].Value)"
        }

        if ($isList) {
            # A list can only start fresh, or nest one level below its parent.
            $level = if ($prevType -ne 'list') { 0 }
                     else { [math]::Min($desiredLevel, $lastListLevel + 1) }
            if ($level -lt 0) { $level = 0 }

            $items.Add([pscustomobject]@{ Kind = 'list'; Level = $level; Text = $content })
            $prevType = 'list'
            $lastListLevel = $level
        }
        else {
            $items.Add([pscustomobject]@{ Kind = 'text'; Level = 0; Text = $body })
            $prevType = 'text'
            $lastListLevel = -1
        }
    }

    return $items
}

function ConvertTo-QuotedMarkdown {
    <#
        Renders the parsed standup items as block-quoted Markdown lines for the
        terminal (Show-Markdown). Questions have their leading number escaped
        ("1\.") so a native ordered list does not renumber them; list items
        become '-' bullets that keep the author's label; plain lines get a hard
        break. Blank '>' separators are inserted between list and text blocks so
        Markdown does not treat a following line as a lazy list continuation.
    #>
    [CmdletBinding()]
    param([string]$Text)

    $items = Get-StandupItems -Text $Text
    $out = [System.Collections.Generic.List[string]]::new()
    $prev = 'blank'

    foreach ($it in $items) {
        switch ($it.Kind) {
            'blank' {
                $out.Add('>')
                $prev = 'blank'
            }
            'question' {
                if ($prev -eq 'list') { $out.Add('>') }
                $escaped = $it.Text -replace '^(\d+)([.)])', '$1\$2'
                $out.Add("> $escaped  ")
                $prev = 'text'
            }
            'text' {
                if ($prev -eq 'list') { $out.Add('>') }
                $out.Add("> $($it.Text)  ")
                $prev = 'text'
            }
            'list' {
                if ($prev -eq 'text') { $out.Add('>') }
                $pad = ' ' * ($it.Level * 4)
                $out.Add("> $pad- $($it.Text)")
                $prev = 'list'
            }
        }
    }

    return $out
}

function Format-InlineHtml {
    <#
        Converts a single line of already-normalised (ConvertFrom-SlackMarkup)
        text into safe inline HTML: undoes the Markdown angle-bracket escapes,
        HTML-encodes the content, then restores bold (**x**) as <strong>.
    #>
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $t = $Text -replace '\\<', '<' -replace '\\>', '>'
    $t = [System.Net.WebUtility]::HtmlEncode($t)
    # Asterisks are not HTML-encoded, so bold markers survive to here.
    $t = [regex]::Replace($t, '\*\*(?<b>.+?)\*\*', '<strong>${b}</strong>')
    return $t
}

function New-NestedListHtml {
    <#
        Builds a properly nested <ul>/<li> tree from a run of list items using
        their computed levels. Markers are suppressed via CSS so the author's
        literal labels (a., ii., 1.) are the visible markers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Items)

    $sb = [System.Text.StringBuilder]::new()
    $prevLevel = $null

    foreach ($it in $Items) {
        $lvl = [int]$it.Level
        $inner = Format-InlineHtml -Text $it.Text

        if ($null -eq $prevLevel) {
            for ($k = 0; $k -le $lvl; $k++) { [void]$sb.Append('<ul>') }
            [void]$sb.Append("<li>$inner")
        }
        elseif ($lvl -gt $prevLevel) {
            for ($k = $prevLevel; $k -lt $lvl; $k++) { [void]$sb.Append('<ul>') }
            [void]$sb.Append("<li>$inner")
        }
        elseif ($lvl -eq $prevLevel) {
            [void]$sb.Append("</li><li>$inner")
        }
        else {
            [void]$sb.Append('</li>')
            for ($k = $prevLevel; $k -gt $lvl; $k--) { [void]$sb.Append('</ul></li>') }
            [void]$sb.Append("<li>$inner")
        }
        $prevLevel = $lvl
    }

    if ($null -ne $prevLevel) {
        [void]$sb.Append('</li>')
        for ($k = $prevLevel; $k -gt 0; $k--) { [void]$sb.Append('</ul></li>') }
        [void]$sb.Append('</ul>')
    }

    return $sb.ToString()
}

function ConvertTo-QuotedHtml {
    <#
        Renders the parsed standup items as an HTML <blockquote> containing
        semantic, properly nested <ul>/<li> lists (labels preserved) and <p>
        paragraphs for questions and plain text.
    #>
    [CmdletBinding()]
    param([string]$Text)

    $items = Get-StandupItems -Text $Text
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<blockquote>')

    $run = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $items) {
        if ($it.Kind -eq 'list') {
            $run.Add($it)
            continue
        }

        # Flush any pending list run before emitting a paragraph.
        if ($run.Count -gt 0) {
            [void]$sb.Append((New-NestedListHtml -Items $run.ToArray()))
            $run.Clear()
        }

        if ($it.Kind -eq 'question' -or $it.Kind -eq 'text') {
            [void]$sb.Append("<p>$(Format-InlineHtml -Text $it.Text)</p>")
        }
        # 'blank' items simply separate blocks.
    }
    if ($run.Count -gt 0) {
        [void]$sb.Append((New-NestedListHtml -Items $run.ToArray()))
    }

    [void]$sb.Append('</blockquote>')
    return $sb.ToString()
}

function Add-EntryMarkdown {
    <#
        Appends a single standup entry (time header plus the block-quoted,
        Markdown-normalised body) to the supplied StringBuilder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)]$Entry
    )

    $prefix = if ($Entry.IsReply) { 'thread reply' } else { 'post' }
    [void]$Builder.AppendLine("**$($Entry.Time)** _($prefix)_")
    [void]$Builder.AppendLine()
    foreach ($mdLine in (ConvertTo-QuotedMarkdown -Text $Entry.Text)) {
        [void]$Builder.AppendLine($mdLine)
    }
    [void]$Builder.AppendLine()
}

function Add-EntryHtml {
    <#
        Appends a single standup entry (time header plus the block-quoted HTML
        body) to the supplied StringBuilder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)]$Entry
    )

    $prefix = if ($Entry.IsReply) { 'thread reply' } else { 'post' }
    [void]$Builder.Append("<p><strong>$([System.Net.WebUtility]::HtmlEncode($Entry.Time))</strong> <em>($prefix)</em></p>")
    [void]$Builder.Append((ConvertTo-QuotedHtml -Text $Entry.Text))
}

# --- Main -----------------------------------------------------------------

Write-Verbose "Resolving channel '#$Channel'..."
$channelId = Resolve-ChannelId -Name $Channel

Write-Verbose 'Fetching workspace users...'
$allMembers = Get-SlackUsers
$userMap = @{}
foreach ($u in $allMembers) { $userMap[$u.id] = Get-UserDisplayName -Member $u }

# Resolve the requested usernames to a set of user IDs. When none are given,
# every author is included.
$targetUserIds = $null
if ($Username) {
    $targetUserIds = [System.Collections.Generic.HashSet[string]]::new()
    $notFound = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Username) {
        $found = $allMembers | Where-Object {
            $member  = $_
            $profile = if ($member.PSObject.Properties['profile']) { $member.profile } else { $null }
            $realName    = if ($member.PSObject.Properties['real_name']) { $member.real_name } else { $null }
            $profReal    = if ($profile -and $profile.PSObject.Properties['real_name']) { $profile.real_name } else { $null }
            $profDisplay = if ($profile -and $profile.PSObject.Properties['display_name']) { $profile.display_name } else { $null }
            $realName -eq $name -or $profReal -eq $name -or $profDisplay -eq $name
        }
        if ($found) {
            foreach ($mm in @($found)) { [void]$targetUserIds.Add($mm.id) }
        } else {
            $notFound.Add($name)
        }
    }
    if ($notFound.Count -gt 0) {
        throw "User(s) not found in the Slack workspace: $($notFound -join ', ')"
    }
}
$includeAll = -not $Username

$oldest = if ($null -ne $StartDate) {
    [DateTimeOffset]$StartDate
} else {
    [DateTimeOffset]::UtcNow.AddMonths(-$Months)
}
$oldestUnix = [Math]::Floor($oldest.ToUnixTimeSeconds())

# When -EndDate is supplied treat it as inclusive. A bare date (midnight) is
# extended to the end of that day so the whole day is covered.
$latest = $null
$latestUnix = $null
if ($null -ne $EndDate) {
    $end = [datetime]$EndDate
    if ($end.TimeOfDay -eq [TimeSpan]::Zero) { $end = $end.Date.AddDays(1).AddTicks(-1) }
    $latest = [DateTimeOffset]$end
    $latestUnix = [Math]::Ceiling($latest.ToUnixTimeSeconds())
}

$rangeStartText = $oldest.ToLocalTime().ToString('yyyy-MM-dd')
$rangeEndText   = if ($latest) { $latest.ToLocalTime().ToString('yyyy-MM-dd') } else { 'now' }

Write-Verbose "Fetching history from $($oldest.ToLocalTime()) to $($(if ($latest) { $latest.ToLocalTime() } else { 'now' })) ..."
$history = if ($null -ne $latestUnix) {
    Get-ChannelHistory -ChannelId $channelId -OldestUnix $oldestUnix -LatestUnix $latestUnix
} else {
    Get-ChannelHistory -ChannelId $channelId -OldestUnix $oldestUnix
}

# Collect the top-level channel messages (all authors, or just the targets).
$collected = [System.Collections.Generic.List[object]]::new()
foreach ($m in $history) {
    $author = if ($m.PSObject.Properties['user']) { $m.user } else { $null }
    if ($m.type -eq 'message' -and $author -and ($includeAll -or $targetUserIds.Contains($author))) {
        $collected.Add([pscustomobject]@{ Message = $m; IsReply = $false })
    }
}

# Walk each thread and collect replies (all authors, or just the targets).
if (-not $ExcludeThreadReplies) {
    $threadParents = $history | Where-Object {
        $_.PSObject.Properties['reply_count'] -and [int]$_.reply_count -gt 0
    }

    foreach ($parent in $threadParents) {
        Write-Verbose "Fetching replies for thread $($parent.ts) ..."
        $replies = if ($null -ne $latestUnix) {
            Get-ThreadReplies -ChannelId $channelId -ThreadTs $parent.ts -OldestUnix $oldestUnix -LatestUnix $latestUnix
        } else {
            Get-ThreadReplies -ChannelId $channelId -ThreadTs $parent.ts -OldestUnix $oldestUnix
        }
        foreach ($r in $replies) {
            $replyAuthor = if ($r.PSObject.Properties['user']) { $r.user } else { $null }
            if ($r.type -eq 'message' -and $replyAuthor -and ($includeAll -or $targetUserIds.Contains($replyAuthor))) {
                $collected.Add([pscustomobject]@{ Message = $r; IsReply = $true })
            }
        }
    }
}

$entries = $collected |
    ForEach-Object {
        $msg  = $_.Message
        $when = [DateTimeOffset]::FromUnixTimeSeconds([long][double]$msg.ts).ToLocalTime()
        $authorId = if ($msg.PSObject.Properties['user']) { $msg.user } else { $null }
        $name = if ($authorId -and $userMap.ContainsKey($authorId)) { $userMap[$authorId] }
                elseif ($authorId) { $authorId }
                else { 'unknown' }
        [pscustomobject]@{
            Channel   = $Channel
            Date      = $when.ToString('yyyy-MM-dd')
            Time      = $when.ToString('HH:mm')
            UserName  = $name
            Timestamp = $msg.ts
            IsReply   = $_.IsReply
            ThreadTs  = if ($msg.PSObject.Properties['thread_ts']) { $msg.thread_ts } else { $null }
            Text      = if ($msg.PSObject.Properties['text']) { $msg.text } else { '' }
        }
    }

# Group primarily by -GroupBy and secondarily by the other field. The entry
# property for 'Username' is 'UserName'.
$primaryProp   = if ($GroupBy -eq 'Username') { 'UserName' } else { 'Date' }
$secondaryProp = if ($GroupBy -eq 'Username') { 'Date' } else { 'UserName' }

# Sort chronologically within each primary group (not also by secondaryProp)
# so that entries for a given day appear earliest-to-latest regardless of
# author. The markdown/browser renderers still sub-group by secondaryProp via
# Group-Object, which preserves this relative (chronological) order within
# each sub-group.
$entries = $entries | Sort-Object $primaryProp, @{ Expression = { [double]$_.Timestamp } }

if ($AsJson) {
    $entries | ConvertTo-Json -Depth 5
}
elseif ($UseBrowser) {
    # Build a semantic HTML document directly (nested <ul>/<li> with the
    # author's literal labels preserved) and open it in the default browser.
    # This bypasses the terminal-oriented Markdown intermediate so list nesting
    # is driven by our computed levels, not a Markdown parser's heuristics.
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $body = [System.Text.StringBuilder]::new()

    $who = if ($Username) { $Username -join ', ' } else { 'all users' }
    [void]$body.Append("<h1>$(& $enc 'Standup entries')</h1>")
    [void]$body.Append("<p><em>Channel:</em> <strong>#$(& $enc $Channel)</strong> &nbsp;&nbsp; <em>From:</em> $(& $enc $rangeStartText) &nbsp;&nbsp; <em>To:</em> $(& $enc $rangeEndText) &nbsp;&nbsp; <em>Users:</em> $(& $enc $who)</p>")

    if (-not $entries) {
        [void]$body.Append('<p><em>No entries found for the selected period.</em></p>')
    }
    else {
        # Two-level grouping driven by -GroupBy (primary) then the other field.
        foreach ($primaryGroup in ($entries | Group-Object $primaryProp | Sort-Object Name)) {
            [void]$body.Append("<h2>$(& $enc $primaryGroup.Name)</h2>")
            foreach ($secondaryGroup in ($primaryGroup.Group | Group-Object $secondaryProp | Sort-Object Name)) {
                [void]$body.Append("<h3>$(& $enc $secondaryGroup.Name)</h3>")
                foreach ($e in $secondaryGroup.Group) {
                    Add-EntryHtml -Builder $body -Entry $e
                }
            }
        }
    }

    $document = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Standup entries</title>
<style>
  body { font-family: 'Segoe UI', Arial, sans-serif; max-width: 900px; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; color: #1f2328; }
  h1 { border-bottom: 2px solid #d0d7de; padding-bottom: .3rem; }
  h2 { border-bottom: 1px solid #d0d7de; padding-bottom: .2rem; margin-top: 2rem; }
  h3 { margin-top: 1.5rem; }
  blockquote { border-left: 4px solid #d0d7de; margin: .4rem 0; padding: .1rem 1rem 1rem; color: #57606a; }
  blockquote p { margin: .4rem 0; }
  /* Labels (a., ii., 1.) are kept as literal text, so hide native markers. */
  ul { list-style: none; margin: .2rem 0; padding-left: 1.5rem; }
  code { background: #f6f8fa; padding: .1rem .3rem; border-radius: 4px; }
  a { color: #0969da; }
</style>
</head>
<body>
$($body.ToString())
</body>
</html>
"@
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("standup-" + [guid]::NewGuid().ToString('N') + ".html")
    Set-Content -Path $tempFile -Value $document -Encoding UTF8
    Write-Verbose "Opening $tempFile in the default browser..."
    Start-Process $tempFile
}
elseif ($AsMarkdown) {
    if (-not (Get-Command -Name Show-Markdown -ErrorAction SilentlyContinue)) {
        throw 'The -AsMarkdown parameter requires PowerShell 7 or the Show-Markdown cmdlet.'
    }

    $sb = [System.Text.StringBuilder]::new()
    $who = if ($Username) { $Username -join ', ' } else { 'all users' }
    [void]$sb.AppendLine('# Standup entries')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("_Channel:_ **#$Channel** &nbsp;&nbsp; _From:_ $rangeStartText &nbsp;&nbsp; _To:_ $rangeEndText &nbsp;&nbsp; _Users:_ $who")
    [void]$sb.AppendLine()

    if (-not $entries) {
        [void]$sb.AppendLine('_No entries found for the selected period._')
    }
    else {
        # Two-level grouping driven by -GroupBy (primary) then the other field.
        foreach ($primaryGroup in ($entries | Group-Object $primaryProp | Sort-Object Name)) {
            [void]$sb.AppendLine("## $($primaryGroup.Name)")
            [void]$sb.AppendLine()
            foreach ($secondaryGroup in ($primaryGroup.Group | Group-Object $secondaryProp | Sort-Object Name)) {
                [void]$sb.AppendLine("### $($secondaryGroup.Name)")
                [void]$sb.AppendLine()
                foreach ($e in $secondaryGroup.Group) {
                    Add-EntryMarkdown -Builder $sb -Entry $e
                }
            }
        }
    }

    $sb.ToString() | Show-Markdown
}
else {
    $entries
}
}
