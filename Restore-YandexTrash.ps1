$BatchSize = 40
$PollInterval = 2

$TotalRestored = 0
$BatchNumber = 0

#--------------------------------------------------------
function Initialize-Session {

    $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $script:Headers = @{}

    $cookiesFile = Join-Path $PSScriptRoot "Cookies.txt"

    if (!(Test-Path $cookiesFile)) {
        throw "Не найден файл Cookies.txt"
    }

    $raw = Get-Content $cookiesFile -Raw

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

    foreach ($m in [regex]::Matches($raw, $cookieRegex)) {

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

        foreach ($m in [regex]::Matches($headerBlock.Groups[1].Value, $lineRegex)) {

            $script:Headers[$m.Groups[1].Value] = $m.Groups[2].Value
        }
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
    Write-Host "Cookies      : $($script:Session.Cookies.Count)"
    Write-Host "Headers      : $($script:Headers.Count)"
    Write-Host "SK           : $script:SK"
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

    $r = Invoke-WebRequest `
        -Uri "https://disk.yandex.ru/models-v2?m=$Method" `
        -Method POST `
        -WebSession $script:Session `
        -ContentType "application/json" `
        -Body $body `
        -Headers $script:Headers

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

        $dst = $r.meta.original_parent_id + $r.name

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

    $oids = @()

    foreach($o in $OperationResult){
        $oids += $o.oid
    }

    if($oids.Count -eq 0){
        return
    }

    while($true){

        Start-Sleep -Seconds $PollInterval

        $status = Invoke-YandexApi "mpfs/bulk-operation-status" @{
            oids = $oids
        }

        $done = 0

        foreach($oid in $oids){

            if($status.PSObject.Properties[$oid].Value.state -eq "COMPLETED"){
                $done++
            }

        }

        Write-Progress `
            -Activity "Восстановление партии" `
            -Status "$done / $($oids.Count)" `
            -PercentComplete (($done/$oids.Count)*100)

        if($done -ge $oids.Count){
            break
        }

    }

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
        break
    }

    if ($null -eq $batch.resources -or $batch.resources.Count -eq 0) {
        Write-Host ""
        Write-Host "Корзина пуста."
        break
    }

    Write-Host ""
    Write-Host "Партия №$BatchNumber"
    Write-Host "Файлов: $($batch.resources.Count)"

    $result = Start-BulkRestore $batch.resources

    Wait-BulkRestore $result

    $TotalRestored += $batch.resources.Count

    Write-Host "Всего восстановлено: $TotalRestored"

    Start-Sleep -Seconds $PollInterval
}

Write-Host ""
Write-Host "================================="
Write-Host "Готово."
Write-Host "Всего восстановлено: $TotalRestored"
Write-Host "================================="