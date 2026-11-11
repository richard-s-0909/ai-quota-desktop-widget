# AI 用量 · 桌面小部件
# 运行: 双击 "启动小部件.vbs"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$Dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Dir 'config.json'
$LogPath    = Join-Path $Dir 'widget.log'
$CodexAuth  = Join-Path $env:USERPROFILE '.codex\auth.json'
$ClaudeExe  = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$ClaudeCred = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$DshCred    = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
$Launcher   = Join-Path $Dir '启动小部件.vbs'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'AI用量小部件.lnk'
$IconFont   = 'Segoe Fluent Icons, Segoe MDL2 Assets'
$NumFont    = 'Segoe UI Variable Display, Segoe UI'
$Accent     = '#FF8B7CFF'

# ---------- 单实例 ----------
$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\AIQuotaDesktopWidget', [ref]$createdNew)
if (-not $createdNew) { exit }

function Write-Log($msg) {
    try { Add-Content -Path $LogPath -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

# ---------- 配置 ----------
function Load-Config {
    $cfg = @{ refresh_minutes = 5; login_warn_days = 3; topmost = $true; left = $null; top = $null
              scale = 1.0; compact = $false; hidden = @(); minimized = $false; tray_tip_shown = $false }
    if (Test-Path $ConfigPath) {
        try {
            $j = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch { Write-Log "读取配置失败: $_" }
    }
    $cfg.hidden = @($cfg.hidden | Where-Object { $_ })
    return $cfg
}
function Save-Config {
    try {
        $json = [pscustomobject]$script:cfg | ConvertTo-Json
        [IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding $false))
    } catch { Write-Log "保存配置失败: $_" }
}
$script:cfg = Load-Config

# ---------- 后台拉取数据 (在独立 runspace 中运行，不卡界面) ----------
$FetchScript = {
    param($CodexAuthPath, $DoClaude, $DoChatGPT, $DoDeepSeek)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # *Action = 'claude' / 'codex' / 'deepseek' 表示需要重新登录；claudeLoginExpires = 整个登录的到期时间
    $r = @{ claude = $null; claudePlan = $null; claudeError = $null; claudeAction = $null; claudeLoginExpires = $null
            chatgpt = $null; chatgptPlan = $null; chatgptError = $null; chatgptAction = $null
            deepseek = $null; deepseekError = $null; deepseekAction = $null }

    function Get-Code($err) {
        try { return [int]$err.Exception.Response.StatusCode } catch { return 0 }
    }
    function To-LocalTime($v) {
        if ($null -eq $v -or $v -eq '') { return $null }
        if ($v -is [DateTime]) { return $v.ToLocalTime() }
        return ([DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
    }

    # ---- Claude (借用本机 Claude Code 的订阅登录，与 claude.ai 用量页同一额度) ----
    if ($DoClaude) {
    try {
        $credPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        if (-not (Test-Path $credPath)) { $r.claudeAction = 'claude'; throw 'Claude 未登录' }
        $cred = Get-Content $credPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $o = $cred.claudeAiOauth
        if (-not $o -or -not $o.accessToken) { $r.claudeAction = 'claude'; throw 'Claude Code 没有用 Claude 订阅账号登录' }
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if ($o.refreshTokenExpiresAt) { $r.claudeLoginExpires = ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$o.refreshTokenExpiresAt)).LocalDateTime }

        # access token 过期则用 refresh token 续期，并写回（与 Claude Code 自己的做法一致，写前先备份）
        if ($o.expiresAt -and [long]$o.expiresAt -lt ($nowMs + 120000) -and $o.refreshToken) {
            $body = @{ grant_type = 'refresh_token'; refresh_token = $o.refreshToken; client_id = '9d1c250a-e61b-44d9-88ed-5944d1962f5e' } | ConvertTo-Json
            $t = $null
            foreach ($url in @('https://platform.claude.com/v1/oauth/token', 'https://console.anthropic.com/v1/oauth/token')) {
                try { $t = Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' -Body $body -UserAgent 'claude-cli' -TimeoutSec 20; break } catch { $lastErr = $_ }
            }
            if (-not $t -or -not $t.access_token) {
                $c = Get-Code $lastErr
                if ($c -eq 400 -or $c -eq 401 -or $c -eq 403) { $r.claudeAction = 'claude'; throw 'Claude 登录已失效' }
                throw '令牌续期失败（网络问题？），稍后会自动重试'
            }
            Copy-Item $credPath "$credPath.bak" -Force
            $o.accessToken = $t.access_token
            if ($t.refresh_token) { $o.refreshToken = $t.refresh_token }
            if ($t.expires_in) { $o.expiresAt = $nowMs + [long]$t.expires_in * 1000 }
            [IO.File]::WriteAllText($credPath, ($cred | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding $false))
        }

        $h = @{ Authorization = "Bearer $($o.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20'; Accept = 'application/json' }
        $u = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $h -UserAgent 'claude-code/2.0' -TimeoutSec 20
        $labels = @{ five_hour = '5 小时'; seven_day = '本周 · 全部模型'; seven_day_opus = '本周 · Opus';
                     seven_day_sonnet = '本周 · Sonnet'; seven_day_oauth_apps = '本周 · 应用'; extra_usage = '额外用量' }
        $rows = @()
        foreach ($p in $u.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [psobject] -and $v.PSObject.Properties['utilization'] -and $null -ne $v.utilization) {
                $label = $labels[$p.Name]; if (-not $label) { $label = $p.Name }
                $rows += @{ label = $label; used = [double]$v.utilization; reset = (To-LocalTime $v.resets_at) }
            }
        }
        $r.claude = $rows
        $r.claudePlan = $o.subscriptionType
    } catch {
        $code = Get-Code $_
        if ($code -eq 401) { $r.claudeAction = 'claude'; $r.claudeError = 'Claude 登录已失效' }
        elseif ($code) { $r.claudeError = "获取失败 (HTTP $code)" }
        else { $r.claudeError = "$($_.Exception.Message)" }
    }
    }

    # ---- ChatGPT (借用本机 Codex 的 ChatGPT 登录) ----
    if ($DoChatGPT) {
    try {
        if (-not (Test-Path $CodexAuthPath)) { $r.chatgptAction = 'codex'; throw '没找到 Codex 登录 (~\.codex\auth.json)' }
        $auth = Get-Content $CodexAuthPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $auth.tokens.access_token) { throw 'Codex 没有用 ChatGPT 账号登录' }
        $h = @{ Authorization = "Bearer $($auth.tokens.access_token)"; 'ChatGPT-Account-Id' = $auth.tokens.account_id; Accept = 'application/json' }
        $d = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' -Headers $h -UserAgent 'codex-usage-widget' -TimeoutSec 20
        $r.chatgptPlan = $d.plan_type
        $rows = @()
        foreach ($w in @($d.rate_limit.primary_window, $d.rate_limit.secondary_window)) {
            if ($null -eq $w) { continue }
            $sec = [int]$w.limit_window_seconds
            if ($sec -eq 18000) { $label = '5 小时' }
            elseif ($sec -eq 604800) { $label = '本周' }
            elseif ($sec -ge 86400) { $label = ('{0} 天' -f [math]::Round($sec / 86400)) }
            else { $label = ('{0} 小时' -f [math]::Round($sec / 3600)) }
            $reset = $null
            if ($w.reset_at) { $reset = ([DateTimeOffset]::FromUnixTimeSeconds([long]$w.reset_at)).LocalDateTime }
            $rows += @{ label = $label; used = [double]$w.used_percent; reset = $reset }
        }
        $r.chatgpt = $rows
    } catch {
        $code = Get-Code $_
        if ($code -eq 401) { $r.chatgptAction = 'codex'; $r.chatgptError = 'ChatGPT / Codex 登录已过期' }
        elseif ($code) { $r.chatgptError = "获取失败 (HTTP $code)" }
        else { $r.chatgptError = "$($_.Exception.Message)" }
    }
    }

    # ---- DeepSeek (借用本机 DeepSeek Harness 的账号登录，查询平台账户余额) ----
    if ($DoDeepSeek) {
    try {
        $dshPath = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
        if (-not (Test-Path $dshPath)) { $r.deepseekAction = 'deepseek'; throw 'DeepSeek Harness 未登录' }
        $y = Get-Content $dshPath -Raw -Encoding UTF8
        $m = [regex]::Match($y, 'deepseek-account-platform/default:[\s\S]*?token:\s*["'']?([^"''\s]+)')
        if (-not $m.Success) { $r.deepseekAction = 'deepseek'; throw 'DeepSeek Harness 没有登录 DeepSeek 账号' }
        $origin = 'https://platform.deepseek.com'
        $im = [regex]::Match($y, 'deepseek-account-platform/default:[\s\S]*?issuer:\s*["'']?(https://[^"''\s]+)')
        if ($im.Success -and $im.Groups[1].Value -match '^https://([a-z0-9-]+\.)*deepseek\.com/?$') { $origin = $im.Groups[1].Value.TrimEnd('/') }
        # 与 DeepSeek Harness 自己查余额的方式一致：令牌放在 x-dsh-auth-token 头里
        $j = Invoke-RestMethod -Uri "$origin/api/v0/users/get_user_summary" -Headers @{ 'x-dsh-auth-token' = $m.Groups[1].Value; Accept = 'application/json' } -UserAgent 'ai-usage-widget' -TimeoutSec 20
        if ($j.code -eq 40003) { $r.deepseekAction = 'deepseek'; throw 'DeepSeek 登录已失效' }
        if ($j.code -ne 0 -or $j.data.biz_code -ne 0) { throw "获取失败 (code $($j.code))" }
        $bd = $j.data.biz_data
        $inv = [Globalization.CultureInfo]::InvariantCulture
        function Num($v) { if ($null -eq $v -or "$v" -eq '') { return 0.0 }; return [double]::Parse([string]$v, [Globalization.NumberStyles]::Float, $inv) }
        $wal = [ordered]@{}
        function Slot($c) { if (-not $wal.Contains($c)) { $wal[$c] = @{ currency = $c; normal = 0.0; bonus = 0.0; tokens = 0.0; cost = 0.0 } }; return $wal[$c] }
        foreach ($w in @($bd.normal_wallets)) { if ($w) { $s = Slot ([string]$w.currency); $s.normal += (Num $w.balance); $s.tokens += (Num $w.token_estimation) } }
        foreach ($w in @($bd.bonus_wallets))  { if ($w) { $s = Slot ([string]$w.currency); $s.bonus  += (Num $w.balance); $s.tokens += (Num $w.token_estimation) } }
        foreach ($c in @($bd.total_costs))    { if ($c) { $s = Slot ([string]$c.currency); $s.cost   += (Num $c.amount) } }
        $list = @($wal.Values | Where-Object { [math]::Abs($_.normal + $_.bonus) -gt 0.000001 -or $_.cost -gt 0.000001 } |
                  Sort-Object { if ($_.currency -eq 'CNY') { 0 } else { 1 } })
        if ($list.Count -eq 0) { $list = @(@{ currency = 'CNY'; normal = 0.0; bonus = 0.0; tokens = 0.0; cost = 0.0 }) }
        $r.deepseek = $list
    } catch {
        $code = Get-Code $_
        if ($code -eq 401) { $r.deepseekAction = 'deepseek'; $r.deepseekError = 'DeepSeek 登录已失效' }
        elseif ($code) { $r.deepseekError = "获取失败 (HTTP $code)" }
        else { $r.deepseekError = "$($_.Exception.Message)" }
    }
    }
    return $r
}

# ---------- 扫描电脑里的 AI ----------
# usage = 能查询剩余用量；其余的只做“已安装 + 一键打开”
$Catalog = @(
    @{ id = 'claude';     name = 'Claude';        color = '#FFD97757'; letter = 'C';  usage = $true;  nameRx = '^Claude$';            appRx = '^AnthropicPBC\.Claude' }
    @{ id = 'chatgpt';    name = 'ChatGPT';       color = '#FF10A37F'; letter = 'G';  usage = $true;  nameRx = '^ChatGPT$';           appRx = '^OpenAI\.' }
    @{ id = 'copilot';    name = 'Copilot';       color = '#FF3B82F6'; letter = 'Co'; nameRx = 'Copilot' }
    @{ id = 'gemini';     name = 'Gemini';        color = '#FF4F8DF7'; letter = 'Ge'; nameRx = 'Gemini' }
    @{ id = 'cursor';     name = 'Cursor';        color = '#FF9CA3AF'; letter = 'Cu'; nameRx = '^Cursor' }
    @{ id = 'windsurf';   name = 'Windsurf';      color = '#FF34D3B4'; letter = 'W';  nameRx = 'Windsurf' }
    @{ id = 'trae';       name = 'Trae';          color = '#FFFF4D6D'; letter = 'T';  nameRx = '^Trae' }
    @{ id = 'deepseek';   name = 'DeepSeek';      color = '#FF4D6BFE'; letter = 'D';  usage = $true;  nameRx = 'DeepSeek Harness|^DeepSeek'; appRx = '^com\.deepseek\.dsh' }
    @{ id = 'doubao';     name = '豆包';          color = '#FF5B8CFF'; letter = '豆'; nameRx = '豆包|Doubao' }
    @{ id = 'kimi';       name = 'Kimi';          color = '#FF64748B'; letter = 'K';  nameRx = 'Kimi' }
    @{ id = 'qwen';       name = '通义';          color = '#FF7C5CFF'; letter = '通'; nameRx = '通义|Qwen|Tongyi' }
    @{ id = 'yuanbao';    name = '腾讯元宝';      color = '#FF22C55E'; letter = '元'; nameRx = '元宝|Yuanbao' }
    @{ id = 'ernie';      name = '文心一言';      color = '#FF2563EB'; letter = '文'; nameRx = '文心|ERNIE' }
    @{ id = 'zhipu';      name = '智谱清言';      color = '#FF3B5BFD'; letter = '智'; nameRx = '智谱|ChatGLM' }
    @{ id = 'perplexity'; name = 'Perplexity';    color = '#FF20B8CD'; letter = 'P';  nameRx = 'Perplexity' }
    @{ id = 'poe';        name = 'Poe';           color = '#FF8B5CF6'; letter = 'Po'; nameRx = '^Poe$' }
    @{ id = 'grok';       name = 'Grok';          color = '#FF6B7280'; letter = 'Gr'; nameRx = '^Grok' }
    @{ id = 'ollama';     name = 'Ollama';        color = '#FF6B7280'; letter = 'O';  nameRx = 'Ollama' }
    @{ id = 'lmstudio';   name = 'LM Studio';     color = '#FF6366F1'; letter = 'LM'; nameRx = 'LM ?Studio' }
    @{ id = 'cherry';     name = 'Cherry Studio'; color = '#FFEF4444'; letter = 'Ch'; nameRx = 'Cherry ?Studio' }
    @{ id = 'chatbox';    name = 'Chatbox';       color = '#FF3B82F6'; letter = 'Cb'; nameRx = 'Chatbox' }
    @{ id = 'lechat';     name = 'Le Chat';       color = '#FFF97316'; letter = 'M';  nameRx = 'Le Chat|Mistral' }
)

function Find-AIs {
    $apps = @()
    try { $apps = @(Get-StartApps) } catch { Write-Log "扫描开始菜单失败: $_" }
    $apps = @($apps | Where-Object { $_.Name -notmatch 'Uninstall|卸载|Setup|Installer' })
    $found = @()
    foreach ($c in $Catalog) {
        $hit = $apps | Where-Object { ($c.appRx -and $_.AppID -match $c.appRx) -or ($_.Name -match $c.nameRx) } | Select-Object -First 1
        $present = [bool]$hit
        if ($c.id -eq 'claude'  -and (Test-Path $ClaudeCred)) { $present = $true }
        if ($c.id -eq 'chatgpt' -and (Test-Path $CodexAuth))  { $present = $true }
        if ($c.id -eq 'deepseek' -and (Test-Path $DshCred))   { $present = $true }
        if ($present) {
            $appId = $null; if ($hit) { $appId = $hit.AppID }
            $found += @{ id = $c.id; name = $c.name; color = $c.color; letter = $c.letter; usage = [bool]$c.usage; appId = $appId }
        }
    }
    return $found
}
function Is-Visible($id) { return -not (@($script:cfg.hidden) -contains $id) }
function Get-Found($id) { return $script:found | Where-Object { $_.id -eq $id } | Select-Object -First 1 }
function Open-AppAction($appId) { return [scriptblock]::Create("Open-App '" + ([string]$appId).Replace("'", "''") + "'") }
function Open-App($appId) {
    if (-not $appId) { return }
    try { Start-Process explorer.exe -ArgumentList ('shell:AppsFolder\' + $appId) } catch { Write-Log "打开应用失败: $_" }
}
$script:found = @(Find-AIs)

# ---------- 样式（极简风） ----------
# 颜色：背景近黑、正文浅灰白、次要灰、提示暗灰；只有“剩余不足”时才出现黄/红
$C = @{
    Bg = '#F5141417'; Border = '#18FFFFFF'; Divider = '#12FFFFFF'
    Text = '#FFEDEDEF'; Sub = '#FF8B8B94'; Faint = '#FF5E5E68'
    Track = '#1CFFFFFF'; Amber = '#FFE5B454'; Red = '#FFE5675C'
}
$StylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="IconBtn" TargetType="Button">
    <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
    <Setter Property="FontSize" Value="10.5"/>
    <Setter Property="Foreground" Value="#FF8B8B94"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Width" Value="24"/>
    <Setter Property="Height" Value="24"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" CornerRadius="6" Background="Transparent">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="B" Property="Background" Value="#14FFFFFF"/>
              <Setter Property="Foreground" Value="#FFEDEDEF"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="IconBtnSm" TargetType="Button" BasedOn="{StaticResource IconBtn}">
    <Setter Property="Width" Value="20"/>
    <Setter Property="Height" Value="20"/>
    <Setter Property="FontSize" Value="9.5"/>
  </Style>
  <Style x:Key="TextBtn" TargetType="Button">
    <Setter Property="Foreground" Value="#FF8B8B94"/>
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border Background="Transparent"><ContentPresenter VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter Property="Foreground" Value="#FFEDEDEF"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="PillBtn" TargetType="Button">
    <Setter Property="Foreground" Value="#FFEDEDEF"/>
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Padding" Value="10,3"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" CornerRadius="6" Background="Transparent" BorderBrush="#2EFFFFFF" BorderThickness="1" Padding="{TemplateBinding Padding}">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="B" Property="Background" Value="#14FFFFFF"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Switch" TargetType="ToggleButton">
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="Track" Width="30" Height="16" CornerRadius="8" Background="#FF2A2A30">
            <Ellipse x:Name="Knob" Width="10" Height="10" Fill="#FF8B8B94" HorizontalAlignment="Left" Margin="3,0,0,0"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Track" Property="Background" Value="#FFEDEDEF"/>
              <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
              <Setter TargetName="Knob" Property="Fill" Value="#FF141417"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="Foreground" Value="#FF8B8B94"/>
    <Setter Property="FontSize" Value="11"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Margin" Value="0,0,4,4"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="B" CornerRadius="6" Padding="10,3" Background="Transparent">
            <ContentPresenter HorizontalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter Property="Foreground" Value="#FFEDEDEF"/>
            </Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="B" Property="Background" Value="#FFEDEDEF"/>
              <Setter Property="Foreground" Value="#FF141417"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="RepeatTrans" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="RepeatFill" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Grid Background="Transparent"><Border Height="2" CornerRadius="1" Background="#FFEDEDEF" VerticalAlignment="Center"/></Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="ZSlider" TargetType="Slider">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Slider">
          <Grid Height="20" Background="Transparent">
            <Border Height="2" CornerRadius="1" Background="#26FFFFFF" VerticalAlignment="Center"/>
            <Track x:Name="PART_Track">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource RepeatFill}" Command="Slider.DecreaseLarge"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource RepeatTrans}" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
              <Track.Thumb>
                <Thumb Cursor="Hand">
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Ellipse Width="12" Height="12" Fill="#FFEDEDEF"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@
$Styles = [Windows.Markup.XamlReader]::Parse($StylesXaml)

# ---------- 主界面 ----------
$Shadow = '<DropShadowEffect BlurRadius="20" ShadowDepth="2" Direction="270" Opacity="0.35" Color="#000000"/>'
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AI 剩余用量" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" FontFamily="Microsoft YaHei UI" UseLayoutRounding="True">
  <Grid x:Name="Root" Margin="14">
    <Grid.LayoutTransform><ScaleTransform x:Name="Zoom" ScaleX="1" ScaleY="1"/></Grid.LayoutTransform>

    <Border x:Name="Card" Width="280" CornerRadius="14" Background="#F5141417" BorderBrush="#18FFFFFF" BorderThickness="1" Padding="18,13,18,12">
      <Border.Effect>@@SHADOW@@</Border.Effect>
      <StackPanel>
        <Grid>
          <TextBlock Text="AI 用量" Foreground="#FF8B8B94" FontSize="11.5" VerticalAlignment="Center"/>
          <StackPanel x:Name="HeaderBtns" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,-4,-8,-4" Opacity="0"/>
        </Grid>
        <StackPanel x:Name="Body"/>
        <Grid Margin="0,14,0,0">
          <TextBlock x:Name="Footer" Foreground="#FF5E5E68" FontSize="10" VerticalAlignment="Center" Text="正在加载…"/>
          <StackPanel x:Name="ZoomCtl" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,-4,-7,-4" Opacity="0"/>
        </Grid>
      </StackPanel>
    </Border>

    <Border x:Name="Pill" Visibility="Collapsed" CornerRadius="16" Background="#F5141417" BorderBrush="#18FFFFFF" BorderThickness="1" Padding="14,5,5,5">
      <Border.Effect>@@SHADOW@@</Border.Effect>
      <StackPanel x:Name="PillBody" Orientation="Horizontal"/>
    </Border>
  </Grid>
</Window>
'@.Replace('@@SHADOW@@', $Shadow)

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$window.Resources.MergedDictionaries.Add($Styles)
foreach ($n in 'Root', 'Zoom', 'Card', 'HeaderBtns', 'Body', 'Footer', 'ZoomCtl', 'Pill', 'PillBody') {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

# ---------- 绘制小工具 ----------
$bc = New-Object System.Windows.Media.BrushConverter
function Brush($hex) { return $bc.ConvertFromString($hex) }

function New-Text($text, $size, $color, $weight = 'Normal', $font = $null) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Foreground = (Brush $color); $t.FontWeight = $weight
    $t.TextWrapping = 'Wrap'; $t.VerticalAlignment = 'Center'
    if ($font) { $t.FontFamily = $font }
    return $t
}
function New-Run($text, $size, $color, $weight = 'Normal', $font = $null) {
    $r = New-Object System.Windows.Documents.Run $text
    $r.FontSize = $size; $r.Foreground = (Brush $color); $r.FontWeight = $weight
    if ($font) { $r.FontFamily = $font }
    return $r
}
# 按钮：点击时执行 $action（存进 Tag，避免 PowerShell 闭包问题）
function New-Button($content, $style, $tip, [scriptblock]$action) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $Styles[$style]; $b.Content = $content; $b.Tag = $action
    if ($tip) { $b.ToolTip = $tip }
    $b.Add_Click({ param($s, $e) try { & $s.Tag } catch { Write-Log "按钮操作失败: $_" } })
    return $b
}
function New-Dot($hex, [double]$size = 6) {
    $d = New-Object System.Windows.Shapes.Ellipse
    $d.Width = $size; $d.Height = $size; $d.Fill = (Brush $hex); $d.VerticalAlignment = 'Center'
    return $d
}
function Add-Col($grid, $width) { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $width; [void]$grid.ColumnDefinitions.Add($cd) }
$GLAuto = [System.Windows.GridLength]::Auto
$GLStar = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)

# 鼠标移到小部件上才显示的元素（标题栏按钮、缩放、打开按钮）
$script:hoverEls = New-Object System.Collections.ArrayList
$script:isHover = $false
function Track-Hover($el) { [void]$script:hoverEls.Add($el); if ($script:isHover) { $el.Opacity = 1 } else { $el.Opacity = 0 } }
function Set-Hover([bool]$on) {
    $script:isHover = $on
    foreach ($el in @($script:hoverEls)) { if ($on) { $el.Opacity = 1 } else { $el.Opacity = 0 } }
}

function Format-Reset($dt) {
    if ($null -eq $dt) { return '' }
    $span = $dt - (Get-Date)
    if ($span.TotalSeconds -le 0) { return '即将重置' }
    if ($span.TotalHours -lt 1) { return ('{0}分钟后重置' -f [math]::Max(1, [int][math]::Floor($span.TotalMinutes))) }
    if ($span.TotalHours -lt 24) { return ('{0}小时{1}分后重置' -f [int][math]::Floor($span.TotalHours), $span.Minutes) }
    $days = '周日', '周一', '周二', '周三', '周四', '周五', '周六'
    return ('{0} {1:HH:mm} 重置' -f $days[[int]$dt.DayOfWeek], $dt)
}
# 剩余充足用正文色，不足才变黄/红
function Level-Color([double]$left) {
    if ($left -lt 10) { return $C.Red }
    if ($left -lt 30) { return $C.Amber }
    return $C.Text
}

# ---------- 数据 → 每个 AI 的显示内容 ----------
$script:last = $null
$script:lastTime = $null
$script:lastOk = $true
function Get-PData($id) {
    $d = $script:last
    if ($null -eq $d) { return $null }
    if ($id -eq 'claude') {
        $plan = $null; if ($d.claudePlan) { $plan = ([string]$d.claudePlan).ToUpper() }
        return @{ rows = $d.claude; plan = $plan; error = $d.claudeError; action = $d.claudeAction; expires = $d.claudeLoginExpires; kind = 'claude' }
    }
    if ($id -eq 'chatgpt') {
        $plan = $null; if ($d.chatgptPlan) { $plan = ([string]$d.chatgptPlan).ToUpper() + ' · Codex' }
        return @{ rows = $d.chatgpt; plan = $plan; error = $d.chatgptError; action = $d.chatgptAction; expires = $null; kind = 'codex' }
    }
    if ($id -eq 'deepseek') {
        # rows = 各币种钱包 @{ currency; normal; bonus; tokens; cost }
        return @{ rows = $d.deepseek; plan = 'API 余额'; error = $d.deepseekError; action = $d.deepseekAction; expires = $null; kind = 'deepseek'; balance = $true }
    }
    return $null
}
function Money($currency, [double]$v, [string]$fmt = 'N2') {
    $sym = '¥'; if ($currency -eq 'USD') { $sym = '$' } elseif ($currency -ne 'CNY') { $sym = "$currency " }
    return $sym + $v.ToString($fmt)
}
function Format-Tokens([double]$n) {
    if ($n -ge 1e9) { return ('{0:0.#}B' -f ($n / 1e9)) }
    if ($n -ge 1e6) { return ('{0:0.#}M' -f ($n / 1e6)) }
    if ($n -ge 1e3) { return ('{0:0.#}K' -f ($n / 1e3)) }
    return ('{0:0}' -f $n)
}
function Balance-Color($w) {
    $total = $w.normal + $w.bonus
    $low = 5; if ($w.currency -eq 'USD') { $low = 1 }
    if ($total -le 0) { return $C.Red }
    if ($total -lt $low) { return $C.Amber }
    return $C.Text
}
function Get-MinLeft($pd) {
    if (-not $pd -or $pd.balance -or -not $pd.rows -or @($pd.rows).Count -eq 0) { return $null }
    return [math]::Round((@($pd.rows) | ForEach-Object { [math]::Max(0, [math]::Min(100, 100 - $_.used)) } | Measure-Object -Minimum).Minimum)
}
# 一句话摘要：迷你模式 / 托盘图标用
function Short-Text($p) {
    $pd = Get-PData $p.id
    if (-not $pd) { return '…' }
    if ($pd.error) { return '!' }
    if ($pd.balance -and $pd.rows) { $w = @($pd.rows)[0]; return (Money $w.currency ($w.normal + $w.bonus) '0') }
    $m = Get-MinLeft $pd
    if ($null -eq $m) { return '…' }
    return "$m%"
}
function Short-Color($p) {
    $pd = Get-PData $p.id
    if (-not $pd) { return $C.Faint }
    if ($pd.error) { return $C.Amber }
    if ($pd.balance -and $pd.rows) { return (Balance-Color @($pd.rows)[0]) }
    $m = Get-MinLeft $pd
    if ($null -eq $m) { return $C.Faint }
    return (Level-Color $m)
}

function Add-Divider {
    $d = New-Object System.Windows.Controls.Border
    $d.Height = 1; $d.Background = (Brush $C.Divider); $d.Margin = '0,13,0,13'
    [void]$Body.Children.Add($d)
}

# 一个 AI 的区块：圆点 + 名称 + 套餐，下面是各个额度
function Add-Section($p, [bool]$animate) {
    $pd = Get-PData $p.id

    $hdr = New-Object System.Windows.Controls.Grid
    Add-Col $hdr $GLStar; Add-Col $hdr $GLAuto
    $left = New-Object System.Windows.Controls.StackPanel; $left.Orientation = 'Horizontal'
    $dot = New-Dot $p.color 6; $dot.Margin = '0,1,8,0'
    [void]$left.Children.Add($dot)
    [void]$left.Children.Add((New-Text $p.name 13 $C.Text 'SemiBold'))
    if ($pd -and $pd.plan) {
        $pl = New-Text $pd.plan 10 $C.Faint; $pl.Margin = '8,1,0,0'
        [void]$left.Children.Add($pl)
    }
    [void]$hdr.Children.Add($left)
    if ($p.appId) {
        $ob = New-Button ([string][char]0xE8A7) 'IconBtnSm' ("打开 " + $p.name) (Open-AppAction $p.appId)
        $ob.Margin = '0,-3,-5,-3'
        [System.Windows.Controls.Grid]::SetColumn($ob, 1)
        Track-Hover $ob
        [void]$hdr.Children.Add($ob)
    }
    [void]$Body.Children.Add($hdr)

    if ($null -eq $pd -or ($null -eq $pd.rows -and -not $pd.error)) {
        $t = New-Text '正在获取…' 11 $C.Faint; $t.Margin = '14,8,0,0'
        [void]$Body.Children.Add($t)
        return
    }

    $watching = $script:watches.ContainsKey($pd.kind)
    if ($pd.error) {
        $et = New-Text $pd.error 11 $C.Red; $et.Margin = '14,8,0,0'
        [void]$Body.Children.Add($et)
        if ($watching) {
            $w = New-Text '正在等待登录完成…' 10.5 $C.Sub; $w.Margin = '14,5,0,0'; [void]$Body.Children.Add($w)
        } elseif ($pd.action) {
            $label = '重新登录 →'; if ($pd.kind -eq 'codex') { $label = '打开 ChatGPT 续期 →' } elseif ($pd.kind -eq 'deepseek') { $label = '打开 DeepSeek 重新登录 →' }
            $btn = New-Button $label 'TextBtn' $null ([scriptblock]::Create("Start-Relogin '$($pd.kind)'"))
            $btn.Margin = '14,6,0,0'; $btn.HorizontalAlignment = 'Left'; $btn.Foreground = (Brush $C.Text)
            [void]$Body.Children.Add($btn)
        }
        return
    }

    if ($pd.balance) { Add-BalanceRows $pd; return }

    foreach ($row in @($pd.rows)) {
        $leftPct = [math]::Max(0, [math]::Min(100, 100 - $row.used))
        $numColor = Level-Color $leftPct
        $barColor = $p.color; if ($leftPct -lt 30) { $barColor = $numColor }

        $line = New-Object System.Windows.Controls.Grid
        $line.Margin = '14,10,0,0'
        $l = New-Object System.Windows.Controls.TextBlock; $l.VerticalAlignment = 'Bottom'
        [void]$l.Inlines.Add((New-Run $row.label 11.5 $C.Sub))
        $rs = Format-Reset $row.reset
        if ($rs) { [void]$l.Inlines.Add((New-Run ('   ' + $rs) 10 $C.Faint)) }
        $v = New-Object System.Windows.Controls.TextBlock
        $v.HorizontalAlignment = 'Right'; $v.VerticalAlignment = 'Bottom'
        [void]$v.Inlines.Add((New-Run ([string][math]::Round($leftPct)) 15 $numColor 'SemiBold' $NumFont))
        [void]$v.Inlines.Add((New-Run '%' 10.5 $C.Sub 'Normal' $NumFont))
        [void]$line.Children.Add($l); [void]$line.Children.Add($v)
        [void]$Body.Children.Add($line)

        # 细进度条（显示剩余部分）
        $bar = New-Object System.Windows.Controls.Grid
        $bar.Margin = '14,6,0,0'; $bar.Height = 3
        Add-Col $bar (New-Object System.Windows.GridLength($leftPct, [System.Windows.GridUnitType]::Star))
        Add-Col $bar (New-Object System.Windows.GridLength((100 - $leftPct), [System.Windows.GridUnitType]::Star))
        $track = New-Object System.Windows.Controls.Border
        $track.CornerRadius = 1.5; $track.Background = (Brush $C.Track)
        [System.Windows.Controls.Grid]::SetColumnSpan($track, 2)
        $fill = New-Object System.Windows.Controls.Border
        $fill.CornerRadius = 1.5; $fill.Background = (Brush $barColor)
        if ($animate) {
            $st = New-Object System.Windows.Media.ScaleTransform 0, 1
            $fill.RenderTransform = $st; $fill.RenderTransformOrigin = New-Object System.Windows.Point 0, 0.5
            $an = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, ([System.Windows.Duration][TimeSpan]::FromMilliseconds(600))
            $ease = New-Object System.Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'; $an.EasingFunction = $ease
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $an)
        }
        [void]$bar.Children.Add($track); [void]$bar.Children.Add($fill)
        [void]$Body.Children.Add($bar)
    }

    # 登录状态提示
    if ($watching) {
        $w = New-Text '正在等待登录完成…' 10.5 $C.Sub; $w.Margin = '14,8,0,0'; [void]$Body.Children.Add($w)
    } elseif ($pd.expires -and ($pd.expires - (Get-Date)).TotalDays -lt [double]$script:cfg.login_warn_days) {
        $wb = New-Object System.Windows.Controls.StackPanel; $wb.Orientation = 'Horizontal'; $wb.Margin = '14,9,0,0'
        [void]$wb.Children.Add((New-Text ('登录 {0:M月d日} 过期  ' -f $pd.expires) 10.5 $C.Amber))
        $btn = New-Button '续期 →' 'TextBtn' $null ([scriptblock]::Create("Start-Relogin '$($pd.kind)'"))
        $btn.Foreground = (Brush $C.Text); $btn.FontSize = 10.5
        [void]$wb.Children.Add($btn)
        [void]$Body.Children.Add($wb)
    }
}

# DeepSeek：余额一行 + 构成一行
function Add-BalanceRows($pd) {
    $multi = @($pd.rows).Count -gt 1
    foreach ($w in @($pd.rows)) {
        $total = $w.normal + $w.bonus
        $color = Balance-Color $w
        $line = New-Object System.Windows.Controls.Grid
        $line.Margin = '14,10,0,0'
        $lbl = '余额'; if ($multi) { $lbl = "余额 · $($w.currency)" }
        $l = New-Text $lbl 11.5 $C.Sub; $l.VerticalAlignment = 'Bottom'
        $v = New-Object System.Windows.Controls.TextBlock
        $v.HorizontalAlignment = 'Right'; $v.VerticalAlignment = 'Bottom'
        $txt = Money $w.currency $total
        [void]$v.Inlines.Add((New-Run $txt.Substring(0, 1) 10.5 $C.Sub 'Normal' $NumFont))
        [void]$v.Inlines.Add((New-Run $txt.Substring(1) 15 $color 'SemiBold' $NumFont))
        [void]$line.Children.Add($l); [void]$line.Children.Add($v)
        [void]$Body.Children.Add($line)

        $parts = @(('充值 ' + (Money $w.currency $w.normal)), ('赠送 ' + (Money $w.currency $w.bonus)))
        if ($w.cost -gt 0) { $parts += ('已用 ' + (Money $w.currency $w.cost)) }
        if ($w.tokens -gt 0) { $parts += ('约 {0} tokens' -f (Format-Tokens $w.tokens)) }
        $d = New-Text ($parts -join ' · ') 10 $C.Faint; $d.Margin = '14,5,0,0'
        [void]$Body.Children.Add($d)
    }
}

# 其他 AI：一行可点击的名称
function Add-Others($list) {
    $wrap = New-Object System.Windows.Controls.WrapPanel
    $lab = New-Text '其他' 10.5 $C.Faint; $lab.Margin = '0,0,10,0'
    [void]$wrap.Children.Add($lab)
    $first = $true
    foreach ($p in $list) {
        if (-not $first) { $sep = New-Text ' · ' 11 $C.Faint; [void]$wrap.Children.Add($sep) }
        $first = $false
        $b = New-Button $p.name 'TextBtn' ("打开 " + $p.name) (Open-AppAction $p.appId)
        [void]$wrap.Children.Add($b)
    }
    [void]$Body.Children.Add($wrap)
}

function Render-Pill {
    $PillBody.Children.Clear()
    $tips = @()
    $usage = @($script:found | Where-Object { $_.usage -and (Is-Visible $_.id) })
    foreach ($p in $usage) {
        $it = New-Object System.Windows.Controls.StackPanel; $it.Orientation = 'Horizontal'; $it.Margin = '0,0,13,0'
        $dot = New-Dot $p.color 6; $dot.Margin = '0,1,6,0'
        [void]$it.Children.Add($dot)
        [void]$it.Children.Add((New-Text (Short-Text $p) 12.5 (Short-Color $p) 'SemiBold' $NumFont))
        [void]$PillBody.Children.Add($it)
        $tips += ($p.name + ' ' + (Short-Text $p))
    }
    if ($usage.Count -eq 0) { $t = New-Text 'AI 用量' 11.5 $C.Sub; $t.Margin = '0,0,10,0'; [void]$PillBody.Children.Add($t) }
    [void]$PillBody.Children.Add((New-Button ([string][char]0xE740) 'IconBtnSm' '展开' { Set-Compact $false }))
    $Pill.ToolTip = (($tips -join '   ') + "`n双击展开").Trim()
}

function Render([bool]$animate = $false) {
    try {
        $Body.Children.Clear()
        $script:hoverEls.Clear()
        foreach ($el in @($HeaderBtns, $ZoomCtl)) { Track-Hover $el }
        $vis = @($script:found | Where-Object { Is-Visible $_.id })
        $usage = @($vis | Where-Object { $_.usage })
        $others = @($vis | Where-Object { -not $_.usage })
        if ($vis.Count -eq 0) {
            $t = New-Text '没有要显示的 AI。右键 → 设置，选择要显示哪些。' 11 $C.Sub; $t.Margin = '0,12,0,0'
            [void]$Body.Children.Add($t)
        }
        $first = $true
        foreach ($p in $usage) {
            if ($first) { $sp = New-Object System.Windows.Controls.Border; $sp.Height = 12; [void]$Body.Children.Add($sp) } else { Add-Divider }
            $first = $false
            Add-Section $p $animate
        }
        if ($others.Count -gt 0) {
            if ($first) { $sp = New-Object System.Windows.Controls.Border; $sp.Height = 12; [void]$Body.Children.Add($sp) } else { Add-Divider }
            Add-Others $others
        }

        if ($script:job) { $Footer.Text = '正在刷新…' }
        elseif ($script:lastTime) {
            $f = ('{0:HH:mm} 更新' -f $script:lastTime)
            if (-not $script:lastOk) { $f += ' · 部分获取失败' }
            $Footer.Text = $f
        }
        Render-Pill
        Update-Tray
    } catch { Write-Log "渲染失败: $_ $($_.InvocationInfo.PositionMessage)"; $Footer.Text = "渲染失败: $($_.Exception.Message)" }
}

# ---------- 异步刷新 ----------
$script:job = $null
function Start-Refresh {
    if ($script:job) { return }
    $doClaude = [bool]((Get-Found 'claude') -and (Is-Visible 'claude'))
    $doGpt    = [bool]((Get-Found 'chatgpt') -and (Is-Visible 'chatgpt'))
    $doDs     = [bool]((Get-Found 'deepseek') -and (Is-Visible 'deepseek'))
    $ps = [powershell]::Create()
    [void]$ps.AddScript($FetchScript.ToString()).AddArgument($CodexAuth).AddArgument($doClaude).AddArgument($doGpt).AddArgument($doDs)
    $script:job = @{ ps = $ps; handle = $ps.BeginInvoke() }
    $Footer.Text = '正在刷新…'
}

$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(400)
$poll.Add_Tick({
    if ($script:job -and $script:job.handle.IsCompleted) {
        $ps = $script:job.ps
        try {
            $out = $ps.EndInvoke($script:job.handle)
            if ($out.Count -gt 0) {
                $script:last = $out[0]; $script:lastTime = Get-Date
                $script:lastOk = -not ($script:last.claudeError -or $script:last.chatgptError -or $script:last.deepseekError)
            }
            foreach ($e in $ps.Streams.Error) { Write-Log "后台错误: $e" }
        } catch { Write-Log "刷新失败: $_"; $script:lastOk = $false }
        finally { $ps.Dispose(); $script:job = $null }
        Render $true
        try { Check-AutoRelogin } catch { Write-Log "自动登录检查失败: $_" }
    }
})
$poll.Start()

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromMinutes([math]::Max(1, [double]$script:cfg.refresh_minutes))
$refreshTimer.Add_Tick({ Start-Refresh })
$refreshTimer.Start()

# 每分钟更新一次倒计时文字
$clock = New-Object System.Windows.Threading.DispatcherTimer
$clock.Interval = [TimeSpan]::FromMinutes(1)
$clock.Add_Tick({ if (-not $script:job) { Render } })
$clock.Start()

# ---------- 重新登录：一键 + 自动 ----------
$script:watches = @{}       # kind -> @{ path; stamp; deadline }
function Get-Stamp($path) { if (Test-Path $path) { return (Get-Item $path).LastWriteTimeUtc } else { return [DateTime]::MinValue } }

# 每 2 秒看一眼登录文件，一旦被更新（登录完成）就立即刷新
$loginWatch = New-Object System.Windows.Threading.DispatcherTimer
$loginWatch.Interval = [TimeSpan]::FromSeconds(2)
$loginWatch.Add_Tick({
    $changed = $false
    foreach ($k in @($script:watches.Keys)) {
        $w = $script:watches[$k]
        if ((Get-Stamp $w.path) -ne $w.stamp) { $script:watches.Remove($k); $changed = $true }
        elseif ((Get-Date) -gt $w.deadline) { $script:watches.Remove($k); Write-Log "$k 登录等待超时"; Render }
    }
    if ($script:watches.Count -eq 0) { $loginWatch.Stop() }
    if ($changed) { Start-Refresh }
})

function Start-Relogin([string]$kind) {
    if ($script:watches.ContainsKey($kind)) { return }
    try {
        if ($kind -eq 'claude') {
            if (-not (Test-Path $ClaudeExe)) { $Footer.Text = '没找到 claude.exe，请先安装 Claude Code'; return }
            $script:watches[$kind] = @{ path = $ClaudeCred; stamp = (Get-Stamp $ClaudeCred); deadline = (Get-Date).AddMinutes(10) }
            # 打开浏览器授权；浏览器已登录 claude.ai 时会自动完成
            Start-Process -FilePath $ClaudeExe -ArgumentList 'auth', 'login'
        } elseif ($kind -eq 'codex') {
            $app = Get-StartApps | Where-Object { $_.AppID -like 'OpenAI.Codex*' } | Select-Object -First 1
            if (-not $app) { $Footer.Text = '没找到 ChatGPT / Codex 应用'; return }
            $script:watches[$kind] = @{ path = $CodexAuth; stamp = (Get-Stamp $CodexAuth); deadline = (Get-Date).AddMinutes(10) }
            Open-App $app.AppID
        } elseif ($kind -eq 'deepseek') {
            $f = Get-Found 'deepseek'
            if (-not $f -or -not $f.appId) { $Footer.Text = '没找到 DeepSeek Harness 应用'; return }
            $script:watches[$kind] = @{ path = $DshCred; stamp = (Get-Stamp $DshCred); deadline = (Get-Date).AddMinutes(10) }
            Open-App $f.appId
        } else { return }
        Write-Log "已打开 $kind 重新登录"
        $loginWatch.Start()
        Render
    } catch {
        $script:watches.Remove($kind)
        Write-Log "打开 $kind 登录失败: $_"; $Footer.Text = "打开登录失败: $($_.Exception.Message)"
    }
}

# 自动触发：同一种登录每天最多自动打开一次，避免反复打扰
function Invoke-AutoRelogin([string]$kind) {
    $key = "auto_login_$kind"
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:cfg[$key] -eq $today -or $script:watches.ContainsKey($kind)) { return }
    $script:cfg[$key] = $today; Save-Config
    Start-Relogin $kind
}
function Check-AutoRelogin {
    $d = $script:last
    if ($null -eq $d) { return }
    if (Is-Visible 'claude') {
        $soon = $d.claudeLoginExpires -and ($d.claudeLoginExpires - (Get-Date)).TotalDays -lt [double]$script:cfg.login_warn_days
        if ($d.claudeAction -or $soon) { Invoke-AutoRelogin 'claude' }
    }
    if ((Is-Visible 'chatgpt') -and $d.chatgptAction) { Invoke-AutoRelogin 'codex' }
    if ((Is-Visible 'deepseek') -and $d.deepseekAction) { Invoke-AutoRelogin 'deepseek' }
}

# ---------- 开机自启 ----------
function Test-Autostart { return (Test-Path $StartupLnk) }
function Set-Autostart([bool]$on) {
    if ($on) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($StartupLnk)
        $lnk.TargetPath = 'wscript.exe'
        $lnk.Arguments = '"' + $Launcher + '"'
        $lnk.WorkingDirectory = $Dir
        $lnk.Save()
    } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
}

# ---------- 缩放 / 迷你模式 / 显示选择 ----------
$ZoomLabel = New-Object System.Windows.Controls.TextBlock
$script:zoomBusy = $false
function Set-Zoom([double]$v) {
    $v = [math]::Round([math]::Max(0.7, [math]::Min(1.8, $v)), 2)
    $Zoom.ScaleX = $v; $Zoom.ScaleY = $v
    $script:cfg.scale = $v
    $ZoomLabel.Text = ('{0}%' -f [math]::Round($v * 100))
    if ($script:settingsWin -and -not $script:zoomBusy) {
        $script:zoomBusy = $true
        try { $sl = $script:settingsWin.FindName('ZoomSlider'); if ([math]::Abs($sl.Value - $v) -gt 0.001) { $sl.Value = $v } } finally { $script:zoomBusy = $false }
        $script:settingsWin.FindName('ZoomVal').Text = $ZoomLabel.Text
    }
    Save-Config
}
# 迷你模式只改变显示形态；托盘弹出时总是显示完整面板
function Apply-View {
    if ($script:cfg.compact -and -not $script:trayMode) { $Card.Visibility = 'Collapsed'; $Pill.Visibility = 'Visible' }
    else { $Card.Visibility = 'Visible'; $Pill.Visibility = 'Collapsed' }
}
function Set-Compact([bool]$on) { $script:cfg.compact = $on; Save-Config; Apply-View }
function Set-Visible([string]$id, [bool]$on) {
    $h = @($script:cfg.hidden | Where-Object { $_ -ne $id })
    if (-not $on) { $h += $id }
    $script:cfg.hidden = $h
    Save-Config
    Render
    if ($on -and (Get-Found $id).usage) { Start-Refresh }
}
function Set-RefreshMinutes([int]$m) {
    $script:cfg.refresh_minutes = $m; Save-Config
    $refreshTimer.Interval = [TimeSpan]::FromMinutes($m)
    Render
}
function Set-Topmost([bool]$on) { $script:cfg.topmost = $on; Save-Config; if (-not $script:trayMode) { $window.Topmost = $on } }

# ---------- 设置窗口（极简） ----------
$script:settingsWin = $null
function Fill-ProviderList {
    $list = $script:settingsWin.FindName('ProvList')
    $list.Children.Clear()
    if (@($script:found).Count -eq 0) { [void]$list.Children.Add((New-Text '没有找到 AI 应用' 11 $C.Sub)); return }
    foreach ($p in $script:found) {
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,10,0,0'
        Add-Col $g $GLAuto; Add-Col $g $GLStar; Add-Col $g $GLAuto
        $dot = New-Dot $p.color 6; $dot.Margin = '0,0,10,0'; $dot.VerticalAlignment = 'Top'; $dot.Margin = '0,6,10,0'
        $txt = New-Object System.Windows.Controls.StackPanel; $txt.VerticalAlignment = 'Center'
        [void]$txt.Children.Add((New-Text $p.name 12.5 $C.Text))
        if ($p.id -eq 'claude')       { if (Test-Path $ClaudeCred) { $s = '可查看剩余用量' } else { $s = '已安装 · 未登录 Claude Code' } }
        elseif ($p.id -eq 'chatgpt')  { if (Test-Path $CodexAuth)  { $s = '可查看剩余用量（Codex 额度）' } else { $s = '已安装 · 未登录' } }
        elseif ($p.id -eq 'deepseek') { if (Test-Path $DshCred)    { $s = '可查看账户余额' } else { $s = '已安装 · 未登录 DeepSeek Harness' } }
        else { $s = '已安装 · 仅快捷打开' }
        $sub = New-Text $s 10 $C.Faint; $sub.Margin = '0,2,0,0'
        [void]$txt.Children.Add($sub)
        $tg = New-Object System.Windows.Controls.Primitives.ToggleButton
        $tg.Style = $Styles['Switch']; $tg.IsChecked = (Is-Visible $p.id); $tg.Tag = $p.id; $tg.VerticalAlignment = 'Center'
        $tg.Add_Click({ param($s, $e) Set-Visible ([string]$s.Tag) ([bool]$s.IsChecked) })
        [System.Windows.Controls.Grid]::SetColumn($txt, 1); [System.Windows.Controls.Grid]::SetColumn($tg, 2)
        [void]$g.Children.Add($dot); [void]$g.Children.Add($txt); [void]$g.Children.Add($tg)
        [void]$list.Children.Add($g)
    }
}

function Show-Settings {
    if ($script:settingsWin) { $script:settingsWin.Activate() | Out-Null; return }
    [xml]$sx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AI 用量 · 设置" Width="352" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        Topmost="True" ShowInTaskbar="True" WindowStartupLocation="CenterScreen" FontFamily="Microsoft YaHei UI" UseLayoutRounding="True">
  <Border Margin="14" CornerRadius="14" Background="#FF141417" BorderBrush="#18FFFFFF" BorderThickness="1" Padding="20,14,20,18">
    <Border.Effect>@@SHADOW@@</Border.Effect>
    <StackPanel>
      <Grid x:Name="TitleBar" Background="Transparent">
        <TextBlock Text="设置" FontSize="13" FontWeight="SemiBold" Foreground="#FFEDEDEF" VerticalAlignment="Center"/>
        <Button x:Name="BtnX" Style="{DynamicResource IconBtn}" Content="&#xE8BB;" HorizontalAlignment="Right" Margin="0,0,-8,0" ToolTip="关闭"/>
      </Grid>

      <TextBlock Text="显示" FontSize="10.5" Foreground="#FF5E5E68" Margin="0,16,0,0"/>
      <StackPanel x:Name="ProvList"/>
      <Button x:Name="BtnScan" Style="{DynamicResource TextBtn}" HorizontalAlignment="Left" Margin="16,12,0,0">
        <TextBlock x:Name="ScanText" Text="重新扫描电脑 →"/>
      </Button>

      <Border Height="1" Background="#12FFFFFF" Margin="0,16,0,0"/>
      <Grid Margin="0,14,0,0">
        <TextBlock Text="大小" FontSize="12.5" Foreground="#FFEDEDEF"/>
        <TextBlock x:Name="ZoomVal" HorizontalAlignment="Right" FontSize="12" Foreground="#FF8B8B94"/>
      </Grid>
      <Slider x:Name="ZoomSlider" Style="{DynamicResource ZSlider}" Minimum="0.7" Maximum="1.8" SmallChange="0.05" LargeChange="0.1" Margin="0,6,0,0"/>
      <TextBlock Text="也可以在小部件上按住 Ctrl 滚动鼠标滚轮" FontSize="10" Foreground="#FF5E5E68" Margin="0,2,0,0"/>

      <TextBlock Text="自动刷新" FontSize="12.5" Foreground="#FFEDEDEF" Margin="0,16,0,8"/>
      <WrapPanel x:Name="RefreshSeg" Margin="-10,0,0,0"/>

      <Border Height="1" Background="#12FFFFFF" Margin="0,10,0,0"/>
      <Grid Margin="0,14,0,0">
        <TextBlock Text="始终置顶" FontSize="12.5" Foreground="#FFEDEDEF" VerticalAlignment="Center"/>
        <ToggleButton x:Name="TgTop" Style="{DynamicResource Switch}" HorizontalAlignment="Right"/>
      </Grid>
      <Grid Margin="0,12,0,0">
        <TextBlock Text="开机自动启动" FontSize="12.5" Foreground="#FFEDEDEF" VerticalAlignment="Center"/>
        <ToggleButton x:Name="TgAuto" Style="{DynamicResource Switch}" HorizontalAlignment="Right"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@.Replace('@@SHADOW@@', $Shadow)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
    $w.Resources.MergedDictionaries.Add($Styles)
    $script:settingsWin = $w

    Fill-ProviderList
    $w.FindName('TitleBar').Add_MouseLeftButtonDown({ try { $script:settingsWin.DragMove() } catch {} })
    $w.FindName('BtnX').Add_Click({ $script:settingsWin.Close() })
    $w.FindName('BtnScan').Add_Click({
        $script:found = @(Find-AIs)
        Fill-ProviderList
        $script:settingsWin.FindName('ScanText').Text = ('扫描完成 · 找到 {0} 个' -f @($script:found).Count)
        Render; Start-Refresh
    })

    $sl = $w.FindName('ZoomSlider'); $sl.Value = [double]$script:cfg.scale
    $w.FindName('ZoomVal').Text = ('{0}%' -f [math]::Round([double]$script:cfg.scale * 100))
    $sl.Add_ValueChanged({ param($s, $e) if (-not $script:zoomBusy) { $script:zoomBusy = $true; try { Set-Zoom ([math]::Round($s.Value / 0.05) * 0.05) } finally { $script:zoomBusy = $false }; $script:settingsWin.FindName('ZoomVal').Text = $ZoomLabel.Text } })

    $seg = $w.FindName('RefreshSeg')
    foreach ($m in 1, 2, 5, 10, 15, 30) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $Styles['Seg']; $rb.GroupName = 'rf'; $rb.Content = "$m 分钟"; $rb.Tag = $m
        $rb.IsChecked = ([int]$script:cfg.refresh_minutes -eq $m)
        $rb.Add_Checked({ param($s, $e) Set-RefreshMinutes ([int]$s.Tag) })
        [void]$seg.Children.Add($rb)
    }

    $tt = $w.FindName('TgTop'); $tt.IsChecked = [bool]$script:cfg.topmost
    $tt.Add_Click({ param($s, $e) Set-Topmost ([bool]$s.IsChecked) })
    $ta = $w.FindName('TgAuto'); $ta.IsChecked = (Test-Autostart)
    $ta.Add_Click({ param($s, $e) try { Set-Autostart ([bool]$s.IsChecked) } catch { Write-Log "自启设置失败: $_"; $s.IsChecked = (Test-Autostart) } })

    $w.Add_Closed({ $script:settingsWin = $null })
    $w.Show()
}

# ---------- 系统托盘 ----------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace AIQuota -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);'

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'AI 用量'
$script:trayHIcon = [IntPtr]::Zero
$script:trayMode = $false          # 窗口当前是否作为“托盘弹出面板”显示
$script:popupHiddenAt = [DateTime]::MinValue

# 托盘图标：深色圆角方块 + 最紧张的剩余百分比
function Update-Tray {
    try {
        $usage = @($script:found | Where-Object { $_.usage -and (Is-Visible $_.id) })
        $min = $null; $tips = @()
        foreach ($p in $usage) {
            $pd = Get-PData $p.id
            $m = Get-MinLeft $pd
            if ($null -ne $m -and ($null -eq $min -or $m -lt $min)) { $min = $m }
            $tips += ($p.name + ' ' + (Short-Text $p))
        }
        $label = 'AI'; $hex = $C.Text
        if ($null -ne $min) { $label = [string][int]$min; $hex = Level-Color $min }

        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = 8; $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $path.AddArc(31 - $r * 2, 0, $r * 2, $r * 2, 270, 90)
        $path.AddArc(31 - $r * 2, 31 - $r * 2, $r * 2, $r * 2, 0, 90); $path.AddArc(0, 31 - $r * 2, $r * 2, $r * 2, 90, 90); $path.CloseFigure()
        $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 24, 24, 28))), $path)
        $fs = 17; if ($label.Length -ge 3) { $fs = 12 }
        $font = New-Object System.Drawing.Font('Segoe UI', $fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $col = [System.Drawing.ColorTranslator]::FromHtml('#' + $hex.Substring(3))
        $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString($label, $font, (New-Object System.Drawing.SolidBrush $col), (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
        $g.Dispose()
        if ($env:AIQUOTA_TRAYPNG) { try { $bmp.Save($env:AIQUOTA_TRAYPNG) } catch {} }
        $h = $bmp.GetHicon(); $bmp.Dispose()
        $tray.Icon = [System.Drawing.Icon]::FromHandle($h)
        if ($script:trayHIcon -ne [IntPtr]::Zero) { [void][AIQuota.Native]::DestroyIcon($script:trayHIcon) }
        $script:trayHIcon = $h

        $tip = 'AI 用量'; if ($tips.Count) { $tip = $tips -join ' · ' }
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + '…' }
        $tray.Text = $tip
    } catch { Write-Log "托盘图标更新失败: $_" }
}

# 托盘弹出：在屏幕右下角显示完整面板，点别处自动收起
function Show-TrayPopup {
    $script:trayMode = $true
    Apply-View
    $window.Topmost = $true
    $window.Opacity = 0                          # 先透明显示量出尺寸，摆好位置再显示，避免闪一下
    $window.Show()
    $window.UpdateLayout()
    $wa = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $wa.Right - $window.ActualWidth + 6
    $window.Top = $wa.Bottom - $window.ActualHeight + 6
    $window.Opacity = 1
    $window.Activate() | Out-Null
}
function Hide-TrayPopup {
    if (-not $script:trayMode) { return }
    $script:trayMode = $false
    $script:popupHiddenAt = Get-Date
    $window.Hide()
    Restore-Position
    Apply-View
    $window.Topmost = [bool]$script:cfg.topmost
}
function Minimize-ToTray {
    $script:cfg.minimized = $true; Save-Config
    $window.Hide()
    if (-not $script:cfg.tray_tip_shown) {
        $script:cfg.tray_tip_shown = $true; Save-Config
        $tray.ShowBalloonTip(4000, 'AI 用量', '已最小化到系统托盘。单击托盘图标查看用量，双击恢复悬浮窗。', 'Info')
    }
}
function Restore-Widget {
    $script:trayMode = $false
    $script:cfg.minimized = $false; Save-Config
    Restore-Position
    Apply-View
    $window.Topmost = [bool]$script:cfg.topmost
    $window.Show()
    $window.Activate() | Out-Null
}

$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:trayMode) { Hide-TrayPopup; return }
    # 刚因为点托盘而失焦收起，不要马上又弹出
    if (((Get-Date) - $script:popupHiddenAt).TotalMilliseconds -lt 400) { return }
    if ($script:cfg.minimized) { Show-TrayPopup } else { $window.Activate() | Out-Null }
})
$tray.Add_MouseDoubleClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-Widget } })

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-TrayItem($text, [scriptblock]$action) {
    $it = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $it.Tag = $action
    $it.Add_Click({ param($s, $e) try { & $s.Tag } catch { Write-Log "托盘菜单失败: $_" } })
    [void]$trayMenu.Items.Add($it)
}
Add-TrayItem '显示悬浮窗' { Restore-Widget }
Add-TrayItem '最小化到托盘' { Minimize-ToTray }
Add-TrayItem '立即刷新' { Start-Refresh }
Add-TrayItem '设置…' { Show-Settings }
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
Add-TrayItem '退出' { Exit-App }
$tray.ContextMenuStrip = $trayMenu

# ---------- 标题栏按钮 / 缩放控件 ----------
[void]$HeaderBtns.Children.Add((New-Button ([string][char]0xE73F) 'IconBtn' '迷你模式' { Set-Compact $true }))
[void]$HeaderBtns.Children.Add((New-Button ([string][char]0xE921) 'IconBtn' '最小化到托盘' { if ($script:trayMode) { Hide-TrayPopup } else { Minimize-ToTray } }))
[void]$HeaderBtns.Children.Add((New-Button ([string][char]0xE713) 'IconBtn' '设置' { Show-Settings }))
[void]$HeaderBtns.Children.Add((New-Button ([string][char]0xE72C) 'IconBtn' '立即刷新' { Start-Refresh }))
[void]$HeaderBtns.Children.Add((New-Button ([string][char]0xE8BB) 'IconBtn' '退出' { Exit-App }))

[void]$ZoomCtl.Children.Add((New-Button ([string][char]0xE738) 'IconBtnSm' '缩小' { Set-Zoom ($script:cfg.scale - 0.1) }))
$ZoomLabel.FontSize = 10; $ZoomLabel.Foreground = (Brush $C.Faint); $ZoomLabel.VerticalAlignment = 'Center'
$ZoomLabel.Cursor = 'Hand'; $ZoomLabel.ToolTip = '点击恢复 100%'; $ZoomLabel.MinWidth = 32; $ZoomLabel.TextAlignment = 'Center'
$ZoomLabel.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Set-Zoom 1.0 })
[void]$ZoomCtl.Children.Add($ZoomLabel)
[void]$ZoomCtl.Children.Add((New-Button ([string][char]0xE710) 'IconBtnSm' '放大' { Set-Zoom ($script:cfg.scale + 0.1) }))

# 鼠标移到小部件上才显示按钮
$Card.Add_MouseEnter({ Set-Hover $true })
$Card.Add_MouseLeave({ Set-Hover $false })

# ---------- 右键菜单 ----------
$menu = New-Object System.Windows.Controls.ContextMenu
function Add-MenuItem($header, [scriptblock]$action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header; $mi.Tag = $action
    $mi.Add_Click({ param($s, $e) & $s.Tag })
    [void]$menu.Items.Add($mi)
}
Add-MenuItem '立即刷新' { Start-Refresh }
Add-MenuItem '设置…' { Show-Settings }
Add-MenuItem '迷你模式 / 展开' { Set-Compact (-not [bool]$script:cfg.compact) }
Add-MenuItem '最小化到托盘' { Minimize-ToTray }
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
Add-MenuItem '放大' { Set-Zoom ($script:cfg.scale + 0.1) }
Add-MenuItem '缩小' { Set-Zoom ($script:cfg.scale - 0.1) }
Add-MenuItem '恢复 100%' { Set-Zoom 1.0 }
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
Add-MenuItem '重新登录 Claude…' { Start-Relogin 'claude' }
Add-MenuItem '打开 ChatGPT 应用续期…' { Start-Relogin 'codex' }
Add-MenuItem '打开 DeepSeek 重新登录…' { Start-Relogin 'deepseek' }
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
Add-MenuItem '退出' { Exit-App }
$window.ContextMenu = $menu

# ---------- 位置 / 拖动 / 滚轮缩放 ----------
$wa = [System.Windows.SystemParameters]::WorkArea
function Restore-Position {
    if ($null -ne $script:cfg.left -and $null -ne $script:cfg.top -and
        [double]$script:cfg.left -ge $wa.Left - 200 -and [double]$script:cfg.left -le $wa.Right - 80 -and
        [double]$script:cfg.top -ge $wa.Top - 40 -and [double]$script:cfg.top -le $wa.Bottom - 80) {
        $window.Left = [double]$script:cfg.left; $window.Top = [double]$script:cfg.top
    } else {
        $window.Left = $wa.Right - 330; $window.Top = $wa.Top + 10
    }
}
Restore-Position

$window.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2 -and $script:cfg.compact -and -not $script:trayMode) { Set-Compact $false; return }
    if ($script:trayMode) { return }
    try { $window.DragMove() } catch {}
    $script:cfg.left = [math]::Round($window.Left); $script:cfg.top = [math]::Round($window.Top); Save-Config
})
$window.Add_PreviewMouseWheel({
    param($s, $e)
    if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
        $e.Handled = $true
        if ($e.Delta -gt 0) { Set-Zoom ($script:cfg.scale + 0.05) } else { Set-Zoom ($script:cfg.scale - 0.05) }
    }
})
# 尺寸变化时：放在屏幕右半边保持右边缘不动；托盘弹出时保持右下角不动
$window.Add_SizeChanged({
    param($s, $e)
    if ($e.PreviousSize.Width -le 0) { return }
    if ($script:trayMode) {
        $window.Left = $window.Left - ($e.NewSize.Width - $e.PreviousSize.Width)
        $window.Top = $window.Top - ($e.NewSize.Height - $e.PreviousSize.Height)
        return
    }
    if ($e.WidthChanged -and ($window.Left + $e.PreviousSize.Width / 2) -gt ($wa.Left + $wa.Width / 2)) {
        $window.Left = $window.Left - ($e.NewSize.Width - $e.PreviousSize.Width)
    }
})
$window.Add_Deactivated({ if ($script:trayMode -and -not $env:AIQUOTA_SHOW) { Hide-TrayPopup } })

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$script:exiting = $false
function Exit-App {
    if ($script:exiting) { return }
    $script:exiting = $true
    $poll.Stop(); $refreshTimer.Stop(); $clock.Stop(); $loginWatch.Stop()
    if ($script:settingsWin) { $script:settingsWin.Close() }
    Save-Config
    $tray.Visible = $false; $tray.Dispose()
    if ($script:trayHIcon -ne [IntPtr]::Zero) { [void][AIQuota.Native]::DestroyIcon($script:trayHIcon) }
    try { $script:mutex.ReleaseMutex() } catch {}
    $app.Shutdown()
}
$window.Add_Closed({ Exit-App })

# 初始状态
$script:zoomBusy = $true; Set-Zoom ([double]$script:cfg.scale); $script:zoomBusy = $false
Apply-View
Render
$tray.Visible = $true
if (-not $script:cfg.minimized) { $window.Show() }
[void]$window.Dispatcher.BeginInvoke([action]{ Start-Refresh })
# 调试用：AIQUOTA_SHOW=settings / tray 启动后直接打开设置或托盘面板（截图验证用）
if ($env:AIQUOTA_SHOW -eq 'settings') { [void]$window.Dispatcher.BeginInvoke([action]{ Show-Settings }) }
if ($env:AIQUOTA_SHOW -eq 'tray') { [void]$window.Dispatcher.BeginInvoke([action]{ Show-TrayPopup }) }
if ($env:AIQUOTA_HOVER) { $Card.Add_MouseLeave({ Set-Hover $true }); Set-Hover $true }
[void]$app.Run()
