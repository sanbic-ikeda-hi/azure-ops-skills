# Azure の初期準備

## 入力を保存して再利用する

基本情報は `LOCALAPPDATA\AzureOpsSkills\user-settings.json` に記録する。実値はリポジトリへ入れない。形式と登録方法は[ユーザー固有情報](authentication.md#ユーザー固有情報の確認と保存)を参照。

~~~powershell
pwsh -NoProfile -File .\scripts\Get-UserSettings.ps1 -Purpose Setup
# ユーザーが実行。不足するTenantId・SandboxSubscriptionIdだけを質問する。
pwsh -NoProfile -File .\scripts\Initialize-AzureOps.ps1
~~~

明示引数が保存値より優先する。任意の本番SubscriptionIdや表示名も事前登録できる。確認画面でyを入力した後、基本情報を保存してAzure初期設定へ進む。対話入力中に確認した不足値は途中保存する。-NonInteractiveは質問・最終確認を省き、必要値がなければAzure接続前に不足項目を示して停止する。値が揃っていれば実際の初期設定へ進むため、状態確認やドライランの代用にしない。

既存のconnection.jsonや進行状況がある場合は、質問・保存・Azure接続より先に停止する。記録に既存ApplicationIdがある場合もアプリを再作成せず、別PC登録または復旧手順を確認する。認証・権限・モジュールの不足を自動修正する機能ではない。以下の従来の明示引数による実行も利用できる。

この手順はユーザーが PowerShell 7 で実行します。Codexに管理者アカウントの接続を渡す手順ではありません。
新規アプリ・証明書・ロールを作成するため、下記の作成内容を確認してから実行してください。

## 必要な情報と権限

| 項目 | 内容 |
| --- | --- |
| TenantId | Microsoft Entra のディレクトリID |
| SandboxSubscriptionId | 読み取りと試験に使うサブスクリプションID |
| ProductionSubscriptionId | 本番の読み取り対象ID。省略すればSandboxのみ |
| アプリ名 | 初期値 azure-ops-skills。既存の同名アプリがあれば停止 |
| アプリ作成権限 | Entra アプリ登録とサービスプリンシパルの作成・証明書登録ができるユーザー |
| Azure 側の権限 | 対象サブスクリプションでカスタムロール作成とロール割り当てができるユーザー。例: 対象サブスクリプションの Owner |
| ローカル環境 | Windows / PowerShell 7.2以降 / Az.Accounts / Az.Resources 10.0.0以降 |

Entra の全体管理者と Azure の Owner は別の権限です。両方の作業が可能なアカウントで実行するか、管理者間で手順を分担してください。
専用アプリ自体には、Entra 管理者ロール、Microsoft Graph のアプリケーション権限、Azure の書き込み権限は付けません。

## 1. Azure PowerShell を準備する

本プロジェクトは Az.Resources 10.0.0以降と、依存する Az.Accounts を使用します。ロール定義は10.0.0以降のPermissions形式です。
必要なモジュールが未導入の場合にユーザーが実行します。ランタイムやグローバル npm パッケージはインストールしません。

~~~powershell
Install-PSResource -Name Az.Resources -Repository PSGallery -Scope CurrentUser
Get-Module -ListAvailable Az.Accounts, Az.Resources | Select-Object Name, Version
~~~

依存関係の取得や認証が失敗した場合は停止してください。実行ポリシーや条件付きアクセスを緩めて回避しません。

## 2. SubscriptionId が分からない場合だけ確認する

ユーザーが別の PowerShell 7 ウィンドウで実行します。

~~~powershell
$tenantId = Read-Host '対象のテナントID'
Disable-AzContextAutosave -Scope Process | Out-Null
try {
    Connect-AzAccount -Tenant $tenantId -Scope Process -ErrorAction Stop | Out-Null
    Get-AzSubscription | Select-Object Name, Id, TenantId, State
}
finally {
    Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
}
~~~

表示されたサブスクリプションの Id を使います。秘密鍵・トークン・パスワードをチャットへ送る必要はありません。

## 3. 専用アプリ・証明書・読み取り権限を作る

リポジトリのルートで、次のスクリプトをユーザーが実行します。サインイン画面で管理権限のあるアカウントを選びます。

~~~powershell
$tenantId = Read-Host '対象のテナントID'
$sandboxSubscriptionId = Read-Host 'SandboxサブスクリプションID'
$productionSubscriptionId = Read-Host '本番サブスクリプションID（不要なら空）'
pwsh -NoProfile -File .\scripts\Initialize-AzureOps.ps1 -TenantId $tenantId -SandboxSubscriptionId $sandboxSubscriptionId -ProductionSubscriptionId $productionSubscriptionId
~~~

作成内容:

1. このPC・Windowsユーザー専用のRSA証明書。有効期間12か月、秘密鍵は書き出し不可として CurrentUser\My に保存。
2. シングルテナントのアプリ登録と、対応するエンタープライズアプリ。
3. アプリへの公開証明書登録。秘密鍵はAzureに送りません。
4. roles/services-reader.json に列挙した管理APIの読み取りだけのカスタムロール。
5. そのロールをSandboxと指定された本番のそれぞれで専用アプリに割り当て。どちらにも変更権限は付与しません。
6. PC側の LOCALAPPDATA\AzureOpsSkills にID・証明書の拇印・進行状況・使用したモジュールバージョンを記録。

読み取りロールの範囲はサブスクリプションですが、権限は3サービスとサブスクリプション/RGの管理メタデータに限定します。
他サービス全体のReaderや、変更・削除・キー取得・実行履歴本文の取得は付与しません。
App Service / Functions / Logic Apps Standard は Microsoft.Web の一部のAPIを共有するため、サービス判定はリソースの種類とkindの両方で行います。
Logic Apps の定義に秘密が直書きされている場合、管理APIの読み取りでもその値を含み得ます。生のレスポンスを表示・保存してはいけません。

## 途中で失敗した場合

- 再実行を重ねません。アプリやロールが部分的に作成されている可能性があります。
- LOCALAPPDATA\AzureOpsSkills\provision-state.json の stage とIDで、どこまで成功したか確認します。
- 作成直後のサービスプリンシパル/ロールの反映待ちもあり得ます。自動再試行や削除は行いません。
- 同名アプリ、同名ロール、既存のPC設定がある場合は自動更新しません。
- ローカル state ファイルを削除して無理に再実行しないでください。成功済み部分を確認し、残りの操作だけを案内します。
- エラーの共有時は、秘密値が含まれていないことを確認してください。

### Invalid value for Permissions で停止した場合

旧形式のロールJSONでは、Az.Resources 10以降のNew-AzRoleDefinitionがこのエラーになります。
現在のroles/services-reader.jsonは、ActionsをPermissions配列内に置く形式へ修正済みです。
Az.Resources 10.2.2 / Az.Accounts 5.5.4が導入済みなら、この修正のためのモジュール再インストールは不要です。

provision-state.jsonのstageがServicePrincipalCreatedで停止した場合は、同じPC・Windowsユーザーで次を実行します。
Initialize-AzureOps.ps1を再実行したり、途中状態や証明書を削除したりしないでください。

~~~powershell
pwsh -NoProfile -File .\scripts\Complete-AzureOpsSetup.ps1
~~~

このコマンドは途中状態から対象IDを読み、既存のアプリとエンタープライズアプリを照合します。
サインインには、そのアプリを読み取り、対象サブスクリプションでロールの作成・割り当てができるアカウントを使います。
作成済みのアプリ・証明書を再利用し、読み取りロールの作成と割り当てだけを続けます。
同名ロールがある場合は名前・操作・割当可能範囲・記録済みIDが一致するときだけ再利用し、異なるものを更新しません。
割り当て済みのものは再作成せず、未完了のものだけ処理します。
再度エラーになった場合は停止し、エラーとstageを確認します。自動再試行・自動削除はありません。

## 4. アプリで読み取りを確認する

権限付与が反映されてから、新しいPowerShellプロセスで実行します。

~~~powershell
pwsh -NoProfile -File .\scripts\Get-ServiceInventory.ps1 -Service AppService -SubscriptionId $sandboxSubscriptionId
pwsh -NoProfile -File .\scripts\Get-ServiceInventory.ps1 -Service Functions -SubscriptionId $sandboxSubscriptionId
pwsh -NoProfile -File .\scripts\Get-ServiceInventory.ps1 -Service LogicApps -SubscriptionId $sandboxSubscriptionId
~~~

上の確認はSandboxで行います。本番を読む場合はSubscriptionIdに本番IDを明示します。前回の接続先を自動利用しません。
管理者ユーザーの接続は流用しません。専用アプリのID・テナント・サブスクリプションを毎回照合します。
取得結果には秘密情報を含む定義やアプリ設定値を出しません。HTTPエラーは「0件」と報告しません。
一覧の0件は、その対象と時点の結果です。別サブスクリプションまで調べた証拠ではありません。

## 5. 共通スキルを配置する

~~~powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
pwsh -NoProfile -File .\scripts\Install-Skills.ps1 -WhatIf
pwsh -NoProfile -File .\scripts\Install-Skills.ps1
~~~

必要ならCodexを再起動し、azure-appservice / azure-functions / azure-logicapps が利用可能か確認します。
現在開いているチャットが自動で新しいスキル一覧に更新されるとは仮定しません。

## 公式資料

- [Azure PowerShell の個別モジュール導入](https://learn.microsoft.com/powershell/azure/install-azps-optimized)
- [証明書でのサービスプリンシパル作成](https://learn.microsoft.com/entra/identity-platform/howto-authenticate-service-principal-powershell)
- [New-AzADApplication](https://learn.microsoft.com/powershell/module/az.resources/new-azadapplication)
- [New-AzADServicePrincipal](https://learn.microsoft.com/powershell/module/az.resources/new-azadserviceprincipal)
- [New-AzADAppCredential](https://learn.microsoft.com/powershell/module/az.resources/new-azadappcredential)
- [カスタムロール作成](https://learn.microsoft.com/azure/role-based-access-control/tutorial-custom-role-powershell)
- [コンテキストの保存](https://learn.microsoft.com/powershell/azure/context-persistence)

- [New-AzRoleDefinitionのPermissions形式](https://learn.microsoft.com/powershell/module/az.resources/new-azroledefinition)
