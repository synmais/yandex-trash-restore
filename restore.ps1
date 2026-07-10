#Requires -Version 5.1

$BatchSize = 40
$PollInterval = 2

$TotalRestored = 0
$BatchNumber = 0

#--------------------------------------------------------
function Initialize-Session {

	$script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
	$script:Headers = @{}

	$cookiesFile = Join-Path $PSScriptRoot "session.txt"

	if (!(Test-Path $cookiesFile)) {
		throw "Не найден файл session.txt"
	}

	$raw = Get-Content -LiteralPath $cookiesFile -Raw

	# ------------------------------------------------------------
	# User-Agent
	# ------------------------------------------------------------

	if ($raw -match '\$session\.UserAgent\s*=\s*"([^"]+)"') {
		$script:Session.UserAgent = $matches[1]
	}

	# ------------------------------------------------------------
	# Cookies
	# ------------------------------------------------------------

	$cookieRegex = '\$session\.Cookies\.Add\(\(New-Object System\.Net\.Cookie\("([^"]+)",\s*"([^"]*)",\s*"([^"]*)",\s*"([^"]*)"\)\)\)'

	$matches = [regex]::Matches($raw, $cookieRegex)

	foreach ($m in $matches) {

		$cookie = New-Object System.Net.Cookie(
			$m.Groups[1].Value,
			$m.Groups[2].Value,
			$m.Groups[3].Value,
			$m.Groups[4].Value
		)

		$script:Session.Cookies.Add($cookie)
	}

	# ------------------------------------------------------------
	# Headers
	# ------------------------------------------------------------

	$headerBlock = [regex]::Match(
		$raw,
		'-Headers\s*@\{(.*?)\}\s*`?\s*-ContentType',
		[System.Text.RegularExpressions.RegexOptions]::Singleline
	)

	if ($headerBlock.Success) {

		$lineRegex = '"([^"]+)"\s*=\s*"((?:[^"]|"")*)"'

		$matches = [regex]::Matches($headerBlock.Groups[1].Value, $lineRegex)

		foreach ($m in $matches) {

			$script:Headers[$m.Groups[1].Value] = $m.Groups[2].Value
		}
	}
	
	if ($script:Headers.ContainsKey("Content-Length")) {
		$script:Headers.Remove("Content-Length")
	}

	# ------------------------------------------------------------
	# SK
	# ------------------------------------------------------------

	if ($raw -match 'sk.*?([0-9a-f]{40}:\d+)') {
		$script:SK = $matches[1]
	}
	else {
		throw "Не удалось найти SK"
	}

	# ------------------------------------------------------------
	# ConnectionId
	# ------------------------------------------------------------

	if ($raw -match 'connection_id.*?(\d{15,})') {
		$script:ConnectionId = $matches[1]
	}
	else {
		throw "Не удалось найти ConnectionId"
	}

	Write-Host ""
	Write-Host "===== Session initialized ====="
	Write-Host "Cookies	  : $($script:Session.Cookies.Count)"
	Write-Host "Headers	  : $($script:Headers.Count)"
	Write-Host "SK		   : $script:SK"
	Write-Host "ConnectionId : $script:ConnectionId"
	Write-Host "==============================="
	Write-Host ""
}

#--------------------------------------------------------
function Invoke-YandexApi {

	param(
		[string]$Method,
		[hashtable]$Params
	)
	
	Write-Host ">> $Method"

	$body = @{
		sk = $script:SK
		connection_id = $script:ConnectionId
		apiMethod = $Method
		requestParams = $Params
	} | ConvertTo-Json -Depth 20 -Compress

	# Write-Host $body

	$params = @{
		Uri			= "https://disk.yandex.ru/models-v2?m=$Method"
		Method		= "POST"
		WebSession	= $script:Session
		ContentType	= "application/json"
		Body		= $body
		Headers		= $script:Headers
	}

	if ($PSVersionTable.PSVersion.Major -lt 6) {
		$params.UseBasicParsing = $true
	}

	$r = Invoke-WebRequest @params -ErrorAction Stop

	$response = $r.Content | ConvertFrom-Json

	return $response
}

#--------------------------------------------------------
function Get-TrashBatch {

	param([int]$Amount)

	Invoke-YandexApi "mpfs/resources" @{
		sort="append_time"
		order="0"
		idContext="/trash"
		amount=$Amount
		offset=0
		with_share="1"
	}
}

#--------------------------------------------------------
function Start-BulkRestore {

	param($Resources)

	$operations = @()

	foreach($r in $Resources){

		$operations += @{
			src = $r.path
			dst = $r.meta.original_parent_id + $r.name
		}

	}

	Invoke-YandexApi "mpfs/bulk-async-restore" @{
		operations = $operations
	}

}

#--------------------------------------------------------
function Wait-BulkRestore {

	param($OperationResult)

	if ($null -eq $OperationResult) {
		return
	}

	$oids = @($OperationResult.items)

	if ($oids.Count -eq 0) {
		return
	}

	while($true){

		Start-Sleep -Seconds $PollInterval

		$status = Invoke-YandexApi "mpfs/bulk-operation-status" @{
			oids = $oids
		}

		$done = 0
		$percent = 0

		foreach ($oid in $oids) {

			$item = $null
			if ($status) {
				$item = $status.PSObject.Properties[$oid].Value
			}

			if ($item -and $item.state -eq "COMPLETED") {
				$done++
			}

		}

		if ($oids.Count -gt 0) {
			$percent = ($done / $oids.Count) * 100
		}

		Write-Progress `
			-Activity "Восстановление партии" `
			-Status "$done / $($oids.Count)" `
			-PercentComplete $percent

		if($done -ge $oids.Count){
			break
		}

	}

	Write-Progress -Activity "Восстановление партии" -Completed

}

Initialize-Session

Write-Host ""
Write-Host "===== Restore Yandex Trash ====="
Write-Host ""

while ($true) {

	$BatchNumber++

	try {
		$batch = Get-TrashBatch -Amount $BatchSize
	}
	catch {
		Write-Host "Ошибка получения списка файлов:"
		Write-Host $_
		Write-Host "Возможно, сессия устарела. Попробуйте обновить session.txt (см. readme)"
		break
	}

	if ((@($batch.resources)).Count -eq 0) {
		Write-Host ""
		Write-Host "Корзина пуста."
		break
	}

	Write-Host ""
	Write-Host "Партия №$BatchNumber"
	Write-Host "Файлов: $((@($batch.resources)).Count)"

	$result = Start-BulkRestore $batch.resources

	Wait-BulkRestore $result

	$TotalRestored += (@($batch.resources)).Count

	Write-Host "Всего восстановлено: $TotalRestored"

	Start-Sleep -Seconds $PollInterval
}

Write-Host ""
Write-Host "================================="
Write-Host "Готово."
Write-Host "Всего восстановлено: $TotalRestored"
Write-Host "================================="