# 別PCへの復元・証明書更新

## 非秘密のユーザー設定を引き継ぐ

`user-settings.json` は基本情報・明示登録した対象・Sandbox条件だけを含み、Git外のアクセス制限された台帳とともに保管できる。別PCで同じLocalAppData配下へ持ち込む場合も、テナント・サブスク・登録対象を確認する。旧PCのconnection.json・秘密鍵・認証キャッシュは接続設定としてコピーしない。lockファイルも移行不要。

旧PCでGet-UserSettings.ps1を使うと、connection.jsonから取得したApplicationIdも確認できる。新PCでは次をユーザーが実行し、不足する既存ApplicationIdなどだけ入力する。

~~~powershell
pwsh -NoProfile -File .\scripts\Get-UserSettings.ps1 -Purpose RegisterComputer
pwsh -NoProfile -File .\scripts\Register-Computer.ps1
~~~

保存済みの項目は聞き直さない。-NonInteractiveは値が不足すれば停止し、揃っていれば実登録する。新PCの証明書作成・公開証明書登録と読み取り確認は従来どおり必要。ユーザー設定の復元だけで接続・権限が復元されたとは扱わない。

GitHubに秘密鍵を保存しなくても復元できます。スキルとスクリプトをcloneし、同じEntraアプリに新PC専用の公開証明書を追加します。
Azureのアプリや既存ロール割当はPCに依存しません。PC移行でアプリを作り直したり、全証明書を置き換えたりしません。

## 事前に保管する情報

社内のアクセス制限された管理台帳に、次の値と本リポジトリのURL/使用コミットを記録します。

- TenantId、SandboxSubscriptionId、ProductionSubscriptionId（設定している場合）
- ApplicationId（クライアントID）
- サービスプリンシパルObjectId
- アプリ登録ObjectId、読み取りRoleId
- PC名・証明書の拇印・有効期限
- LOCALAPPDATA\AzureOpsSkills\module-versions.json に記録されたAzモジュールのバージョン

これらは認証用の秘密鍵ではありません。実環境の識別情報としてGitの外で管理します。
旧PCの connection.json / provision-state.json / module-versions.json は、この情報の控えに利用できます。
秘密鍵・PFX・認証キャッシュ・トークンをバックアップに混ぜません。

## 新PC

1. Windows / PowerShell 7 / Gitを組織の方法で準備する。ランタイムは既存のmise運用に従う。
2. 本リポジトリをcloneする。URLは自分のGitHubリポジトリを指定する。
3. Azモジュールを準備する。旧PCで記録したバージョンを指定して再現する。記録がない場合は最新の導入を別途判断し、同じ版とは報告しない。
4. 新PC用証明書を登録する。
5. 読み取り・スキル配置を確認する。

~~~powershell
git clone '<自分のGitHubリポジトリURL>' azure-ops-skills
Set-Location .\azure-ops-skills

# 値は旧PCの module-versions.json から入力。表示例をそのまま版番号にしない。
$accountsVersion = Read-Host '記録した Az.Accounts の版番号'
$resourcesVersion = Read-Host '記録した Az.Resources の版番号'
Install-PSResource -Name Az.Accounts -Version $accountsVersion -Repository PSGallery -Scope CurrentUser
Install-PSResource -Name Az.Resources -Version $resourcesVersion -Repository PSGallery -Scope CurrentUser

$tenantId = Read-Host 'テナントID'
$sandboxSubscriptionId = Read-Host 'SandboxサブスクリプションID'
$productionSubscriptionId = Read-Host '本番サブスクリプションID（不要なら空）'
$applicationId = Read-Host '既存の専用アプリのクライアントID'
pwsh -NoProfile -File .\scripts\Register-Computer.ps1 -TenantId $tenantId -SandboxSubscriptionId $sandboxSubscriptionId -ProductionSubscriptionId $productionSubscriptionId -ApplicationId $applicationId

pwsh -NoProfile -File .\scripts\Get-ServiceInventory.ps1 -Service AppService -SubscriptionId $sandboxSubscriptionId
pwsh -NoProfile -File .\scripts\Get-ServiceInventory.ps1 -Service Functions -SubscriptionId $sandboxSubscriptionId
pwsh -NoProfile -File .\scripts\Get-ServiceInventory.ps1 -Service LogicApps -SubscriptionId $sandboxSubscriptionId
pwsh -NoProfile -File .\scripts\Install-Skills.ps1 -WhatIf
pwsh -NoProfile -File .\scripts\Install-Skills.ps1
~~~

Register-Computer.ps1 は、サインインしたユーザーに既存アプリの証明書を追加する権限が必要です。
ロールの作成・付与はしません。新PCで実際に読み取れたことは別に確認します。
旧PCの connection.json を新PCの接続設定として上書きコピーしません。証明書の拇印はPCごとに異なります。
モジュールの版はインストール後に確認し、依存解決で異なる版が選ばれた場合は記録します。

## Microsoft製スキルも併用する場合

本リポジトリの復元で配置されるのは独自の3スキルとPowerShellヘルパーです。Microsoft製スキルは別管理です。
旧PCで利用したスキル名、提供元microsoft/azure-skills、スキルのmetadata.version、入手元のタグまたはコミット（分かる場合）も記録します。
新PCでは必要なスキルだけ、導入方法と内容を確認してユーザーが追加します。全スキルやCLI・拡張機能を自動導入しません。
未導入でも基本一覧取得は可能です。詳細調査はMicrosoft Learnで補い、Microsoft製スキルを利用できたとは報告しません。
導入・更新後は対応サービス、依存ツール、認証方法、書き込み操作の有無を再確認します。スキルを追加してもAzure権限は自動追加しません。

## IDの控えを紛失した場合

管理者ユーザーで対象テナントにサインインし、アプリを表示名で検索します。
同名が複数なら停止し、所有者・作成日時・台帳などで対象を照合します。

~~~powershell
Get-AzADApplication -DisplayName 'azure-ops-skills' |
    Select-Object DisplayName, AppId, Id
~~~

AppIdがクライアントID、Idがアプリ登録ObjectIdです。エンタープライズアプリのObjectIdとは別です。
アプリ名だけで既存アプリを更新・削除しません。

## 証明書の期限更新・旧PCの廃止

- 新しい証明書を追加し、その証明書で読み取りを確認してから、古い登録を1件だけ削除します。
- 同じPCの期限更新では、既存profileを控えたうえで新証明書を作成し、新しい拇印への切替を個別に案内します。Register-Computer.ps1は既存profileを自動上書きしません。
- 削除前にアプリのKeyId・拇印・有効期限・対応PCを照合してください。
- KeyIdを指定しない資格情報の全件削除は使用しません。
- PC紛失時は、まずそのPCの資格情報を失効させる対応を管理者が行います。
- Azureアプリ自体を削除した場合は新規作成とRBAC再設定が必要です。単なるPC移行と区別してください。

[Microsoft: 証明書の追加と資格情報の変更](https://learn.microsoft.com/entra/identity-platform/howto-authenticate-service-principal-powershell#change-credentials)
