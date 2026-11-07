#requires -Version 7.2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'AppServiceReadiness.ps1')
$checks=0
function Check($ok,$name){if(-not $ok){throw $name};$script:checks++}
function Run-Sequence($Sequence,[int]$Budget=30,[int]$ProbeDuration=100){
 $state=@{ms=0;index=0;limits=@();delays=@();events=@()}
 $probe={param($uri,$limit,$token,$status,$body)
  $state.limits+=,$limit;$state.ms+=[Math]::Min($ProbeDuration,$limit)
  $s=$Sequence[[Math]::Min($state.index,$Sequence.Count-1)];$state.index++
  @{Kind=$(if($s -is [string]){$s}else{'Response'});HttpStatus=$(if($s -is [int]){$s}else{$null});Matches=($s -eq 200)}
 }
 $result=Wait-OpsAppServiceReady -Uri 'https://test.invalid/healthz' -OverallSeconds $Budget -Probe $probe -Clock {$state.ms} -Delay {param($ms,$token)$state.delays+=,$ms;$state.ms+=$ms} -Record {param($e)$state.events+=,$e}
 @{Result=$result;State=$state}
}
$r=Run-Sequence @('RequestTimeout',503,200,200)
Check $r.Result.ReadyObserved 'Timeout and startup response can recover'
Check ($r.State.events.Count -eq 4) 'Every observation recorded'
$r=Run-Sequence @(200,503,200,200)
Check ($r.Result.Attempts -eq 4) 'Success counter resets'
foreach($s in @(401,403,302,404,500,'TransportFailure')){
 $r=Run-Sequence @($s);Check (-not $r.Result.ReadyObserved -and $r.Result.Attempts -eq 1) "Stops: $s"
}
$r=Run-Sequence @(503) 2 10000
Check ($r.Result.Outcome -eq 'DeadlineExpired' -and $r.State.ms -eq 2000 -and $r.State.limits[0] -eq 2000) 'Request capped to remaining budget'
$r=Run-Sequence @(503) 2 100
Check ($r.State.ms -eq 2000 -and $r.State.delays[0] -eq 1900) 'Sleep capped to remaining budget'
$cts=[Threading.CancellationTokenSource]::new();$cts.Cancel()
try{$r=Wait-OpsAppServiceReady -Uri 'https://test.invalid/healthz' -CancellationToken $cts.Token;Check ($r.Outcome -eq 'Canceled' -and $r.Attempts -eq 0) 'Canceled before request'}finally{$cts.Dispose()}
Check (-not $r.AuthenticationVerified -and -not $r.BusinessRequestVerified -and -not $r.ProcessRestartVerified) 'Readiness does not claim sign-in, business success or restart'
# Real loopback HTTP, including timeout during headers/body and cancellation.
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class OpsHealthFixture : IDisposable {
 readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
 readonly CancellationTokenSource stop = new CancellationTokenSource();
 readonly Task worker;
 public int Port { get; }
 public OpsHealthFixture(int status, int headerDelay, int bodyDelay) {
  listener.Start(); Port=((IPEndPoint)listener.LocalEndpoint).Port;
  worker=Task.Run(async () => {
   try { using(var socket=await listener.AcceptTcpClientAsync()) {
    var stream=socket.GetStream(); var b=new byte[4096]; await stream.ReadAsync(b,0,b.Length,stop.Token);
    await Task.Delay(headerDelay,stop.Token);
    var body=Encoding.UTF8.GetBytes("{\"status\":\"ok\"}");
    var header=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" Test\r\nContent-Length: "+body.Length+"\r\nLocation: https://example.invalid/\r\nConnection: close\r\n\r\n");
    await stream.WriteAsync(header,0,header.Length,stop.Token);
    await Task.Delay(bodyDelay,stop.Token); await stream.WriteAsync(body,0,body.Length,stop.Token);
   }} catch { }
  });
 }
 public void Dispose() { stop.Cancel();listener.Stop();worker.GetAwaiter().GetResult();stop.Dispose(); }
}
'@
foreach($case in @(@{status=302;headers=0;body=0;kind='Response'},@{status=200;headers=3000;body=0;kind='RequestTimeout'},@{status=200;headers=0;body=3000;kind='RequestTimeout'},@{status=200;headers=0;body=0;kind='Response'})){
 $fixture=[OpsHealthFixture]::new($case.status,$case.headers,$case.body)
 try {
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $p=Invoke-OpsReadinessProbe ([uri]("http://127.0.0.1:"+$fixture.Port+'/healthz')) 300 ([Threading.CancellationToken]::None) 200 'ok'
  Check ($p.Kind -eq $case.kind) 'Real transport result'
  if($case.status -eq 302){Check ($p.HttpStatus -eq 302 -and -not $p.Matches) '302 observed without following redirect'}
  if($case.headers -or $case.body){Check ($timer.Elapsed.TotalSeconds -lt 2) 'In-flight request/body bounded'}
  if($case.status -eq 200 -and -not $case.headers -and -not $case.body){Check $p.Matches 'Expected backend JSON checked'}
 }finally{$fixture.Dispose()}
}
$fixture=[OpsHealthFixture]::new(200,3000,0);$cts=[Threading.CancellationTokenSource]::new();$cts.CancelAfter(100)
try{$p=Invoke-OpsReadinessProbe ([uri]("http://127.0.0.1:"+$fixture.Port+'/')) 3000 $cts.Token 200 'ok';Check ($p.Kind -eq 'Canceled') 'In-flight user cancellation'}finally{$cts.Dispose();$fixture.Dispose()}
Write-Output "PASS: $checks readiness checks; synthetic clock and loopback HTTP, no cloud requests."
