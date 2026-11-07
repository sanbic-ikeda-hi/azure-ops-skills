#requires -Version 7.2
# Read-only health GET. No Azure authentication, cookies, redirects or mutation here.
function Invoke-OpsReadinessProbe {
    param([uri]$Uri,[int]$TimeoutMilliseconds,[Threading.CancellationToken]$CancellationToken,
        [int]$ExpectedStatus=200,[string]$ExpectedJsonStatus='')
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false
    $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $cts=[Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
    $cts.CancelAfter($TimeoutMilliseconds);$response=$null;$message=$null
    try {
        $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$Uri)
        $message.Headers.CacheControl=[Net.Http.Headers.CacheControlHeaderValue]::new()
        $message.Headers.CacheControl.NoCache=$true
        $response=$client.SendAsync($message,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).WaitAsync($cts.Token).GetAwaiter().GetResult()
        $status=[int]$response.StatusCode;$matches=$status -eq $ExpectedStatus
        if($matches -and $ExpectedJsonStatus){
            $stream=$response.Content.ReadAsStreamAsync($cts.Token).WaitAsync($cts.Token).GetAwaiter().GetResult()
            try {
                $buffer=[byte[]]::new(4097);$length=0
                do {
                    $read=$stream.ReadAsync($buffer,$length,$buffer.Length-$length,$cts.Token).WaitAsync($cts.Token).GetAwaiter().GetResult()
                    $length+=$read
                }while($read -gt 0 -and $length -lt $buffer.Length)
                $matches=$false
                if($length -le 4096){
                    try {$json=[Text.Encoding]::UTF8.GetString($buffer,0,$length)|ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        $matches=$json -is [Collections.IDictionary] -and $json['status'] -is [string] -and $json['status'] -ceq $ExpectedJsonStatus
                    }catch{$matches=$false}
                }
            }finally{$stream.Dispose()}
        }
        return @{Kind='Response';HttpStatus=$status;Matches=$matches}
    } catch {
        $ex=$_.Exception.GetBaseException();$kind='TransportFailure'
        if($CancellationToken.IsCancellationRequested){$kind='Canceled'}
        elseif($ex -is [OperationCanceledException]){$kind='RequestTimeout'}
        return @{Kind=$kind;HttpStatus=$null;Matches=$false}
    } finally {
        if($response){$response.Dispose()};if($message){$message.Dispose()}
        $cts.Dispose();$client.Dispose()
    }
}
function Wait-OpsAppServiceReady {
    param([Parameter(Mandatory)][uri]$Uri,
        [ValidateRange(1,1800)][int]$OverallSeconds=300,[ValidateRange(1,120)][int]$RequestSeconds=10,
        [ValidateRange(1,60)][int]$IntervalSeconds=5,[ValidateRange(1,10)][int]$ConsecutiveSuccesses=2,
        [ValidateRange(200,299)][int]$ExpectedStatus=200,[string]$ExpectedJsonStatus='',
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None,
        [scriptblock]$Record={param($event)},[scriptblock]$Probe=${function:Invoke-OpsReadinessProbe},
        [scriptblock]$Clock,[scriptblock]$Delay)
    if($Uri.Scheme -ne 'https' -or -not $Uri.IsDefaultPort -or $Uri.UserInfo -or $Uri.Query -or $Uri.Fragment){throw 'Expected HTTPS health URI without credentials, query or fragment.'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    if(-not $Clock){$Clock={$watch.Elapsed.TotalMilliseconds}}
    if(-not $Delay){$Delay={param($ms,$token) [Threading.Tasks.Task]::Delay([int]$ms,$token).GetAwaiter().GetResult()}}
    $start=[double](& $Clock);$budget=$OverallSeconds*1000;$success=0;$attempt=0;$outcome='DeadlineExpired'
    while($true){
        $remaining=$budget-([double](& $Clock)-$start)
        if($CancellationToken.IsCancellationRequested){$outcome='Canceled';break}
        if($remaining -lt 1){break}
        $attempt++;$began=[DateTime]::UtcNow.ToString('o');$at=[double](& $Clock)
        $limit=[int][Math]::Floor([Math]::Min($RequestSeconds*1000,$remaining))
        $observation=& $Probe $Uri $limit $CancellationToken $ExpectedStatus $ExpectedJsonStatus
        $elapsed=[double](& $Clock)-$start
        & $Record ([ordered]@{Stage='HealthObservation';Attempt=$attempt;StartedAtUtc=$began;EndedAtUtc=[DateTime]::UtcNow.ToString('o');ElapsedMilliseconds=([double](& $Clock)-$at);Kind=$observation.Kind;HttpStatus=$observation.HttpStatus;Matches=$observation.Matches}) | Out-Null
        if($CancellationToken.IsCancellationRequested -or $observation.Kind -eq 'Canceled'){$outcome='Canceled';break}
        if($elapsed -ge $budget){break}
        if($observation.Kind -eq 'Response' -and $observation.Matches){$success++}else{$success=0}
        if($success -ge $ConsecutiveSuccesses){$outcome='ReadyObserved';break}
        if($observation.Kind -eq 'Response'){
            if($observation.HttpStatus -notin @(502,503,504) -and -not $observation.Matches){$outcome='UnexpectedResponse';break}
        }elseif($observation.Kind -ne 'RequestTimeout'){$outcome='TransportFailure';break}
        $remaining=$budget-([double](& $Clock)-$start)
        if($remaining -lt 1){break}
        try {& $Delay ([Math]::Min($IntervalSeconds*1000,$remaining)) $CancellationToken | Out-Null}
        catch {if($CancellationToken.IsCancellationRequested){$outcome='Canceled';break};throw 'Readiness wait failed. Details omitted.'}
    }
    [ordered]@{Outcome=$outcome;ReadyObserved=($outcome -eq 'ReadyObserved');Attempts=$attempt;ElapsedMilliseconds=([double](& $Clock)-$start);AuthenticationVerified=$false;BusinessRequestVerified=$false;ProcessRestartVerified=$false}
}
