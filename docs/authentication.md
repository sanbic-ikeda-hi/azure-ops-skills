# 共通認証と実行環境

## ユーザー固有情報の確認と保存

接続情報は `LOCALAPPDATA\AzureOpsSkills\connection.json`、追加の非秘密設定は同じフォルダーの `user-settings.json` に置く。3スキルとソースは同じ保存先を参照し、案件フォルダーや現在の作業ディレクトリから設定を探さない。

Azure操作の前に、ソースではscripts、配布先ではSKILL.mdの隣のscriptsにあるGet-UserSettings.ps1を使う。

~~~powershell
pwsh -NoProfile -File '<HELPER_PATH>\Get-UserSettings.ps1'
pwsh -NoProfile -File '<HELPER_PATH>\Get-UserSettings.ps1' -Alias '登録した別名'
pwsh -NoProfile -File '<HELPER_PATH>\Get-UserSettings.ps1' -SandboxName LogicApps
~~~

- 保存値とMissingFieldsを確認し、依頼に必要な不足項目だけチャットで質問する。セットアップなら-Purpose Setup、別PC登録なら-Purpose RegisterComputerを使う。生成するアプリID・ObjectId・証明書拇印は事前入力させない。既存アプリを別PCへ登録する場合だけApplicationIdを確認する。
- 値が揃っている項目を聞き直さない。別名は大文字小文字を区別せず完全一致を優先し、部分一致の候補が複数なら選択を求める。未一致を既定対象へ置き換えない。
- 基本情報の確認・保存とAzure操作の承認は別。RG・リソース・Sandbox条件は「登録して」「覚えて」などの指示がある場合だけ保存する。一時的に調べた対象を自動登録しない。
- 保存設定とconnection.jsonのテナント・アプリ・Sandbox・許可サブスクが食い違う場合は停止する。ユーザー設定を書いても接続先・認証・RBACは変わらない。
- ConnectionPresentは接続ファイルの存在と形式を示す。証明書・Azure接続・現在の権限の検証ではなく、AzureVerifiedは常にfalse。登録対象の種別・所在地・関連IDも保存時点の控えとして扱い、変更前にGETで照合する。

保存はSet-UserSettings.ps1へJSONの部分更新を渡す。以下は構造例。実IDは確認して置換し、秘密情報は入力しない。

~~~powershell
$patch = @{
    basic = @{ tenantId='<TENANT_ID>'; sandboxSubscriptionId='<SANDBOX_SUBSCRIPTION_ID>' }
} | ConvertTo-Json -Depth 8
$patch | & '<HELPER_PATH>\Set-UserSettings.ps1'
# -WhatIfなら保存しない
~~~

### 設定の形式と更新

ルートはschemaVersion=1、basic、targets、sandbox。部分更新で渡さない項目は残す。未対応項目・空値・不正ID・未知の版は拒否し、壊れた既存ファイルを初期化しない。同時更新をロックで排他し、一時ファイルから置き換える。保存失敗時は元ファイルを残して停止する。user-settings.json.lockには設定値を保存しない。

| 区分 | 許可する情報 |
| --- | --- |
| basic | tenantId、sandboxSubscriptionId、productionSubscriptionId〔任意〕、applicationId〔既存アプリ〕、displayName。表示名の既定値はazure-ops-skills |
| targets | alias、kind〔Resource／ResourceGroup〕、service〔AppService／Functions／LogicApps〕、完全なresourceId、location、関連するplanResourceId・storageResourceId |
| sandbox.LogicApps | resourceGroupName、workflowName、location |
| sandbox.Functions | resourceGroupName、functionAppName、planName、storageAccountName、location |
| sandbox.AppServiceFixture | resourceGroupName、planName、appName、location、sku。作成方式は従来どおりLinux |
| sandbox.WebAppTest | resourceId、planResourceId、peerResourceId、location、operatingSystem〔Windows／Linux〕、sku〔B1／P0v4〕 |
| sandbox.FunctionsTest | resourceId、planResourceId、storageResourceId、managedIdentityObjectId、location。Flex/Linux/FC1など試験方式の条件は変更しない |

targetsは配列で、各登録にはalias・kind・resourceIdが必要。Resourceにはserviceも必要。aliasは全登録で一意とし、更新時は同じaliasの登録だけを差し替える。RGのIDは候補用であり、RG全体への変更許可には使わない。App ServiceとFunctionsのkind、Logic AppsのConsumption／Standardは実取得して判定する。

sandboxはシナリオごとのオブジェクトで、途中まで保存できる。実行時は明示引数を優先し、不足分だけ登録条件を使う。揃わなければ質問を案内して終了し、固定名・既定リージョンで補完しない。Web App／Functionsの完全ID・割当IDの必須引数は維持する。Remove／Revokeでは保存値から対象を補完せず、対象を明示する。

例のゼロGUIDやプレースホルダーは実行用として拒否する。実設定をテンプレートへ書き戻さない。項目の削除や接続先の移行はこの部分更新コマンドの対象外。必要なら対象と影響を示して個別に案内する。

3サービスの認証処理はscripts/Authentication.ps1で共有し、既存のscripts/Common.ps1から読み込む。独立した事前サインインのスクリプトではない。

## 必須環境と不足時の案内

- Windows、PowerShell 7.2以降。
- Azure PowerShell の Az.Accounts と Az.Resources。Azモジュール全体やAzure CLIは必須にしない。
- 専用アプリの接続プロファイルと、このWindowsユーザーの証明書ストアにある有効な秘密鍵付き証明書。

初回実行・別PCでの実行前に、次の読み取りだけの確認を行う。

~~~powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable Az.Accounts, Az.Resources | Select-Object Name, Version
~~~

不足がある場合は、その項目をユーザーへ伝えて停止する。Azモジュール未導入なら、PowerShell 7で次を実行するよう案内する。

~~~powershell
Install-PSResource -Name Az.Resources -Repository PSGallery -Scope CurrentUser
~~~

Az.Accountsは依存関係として導入される。モジュール導入後に両方の版を確認する。
インストール・更新・ダウングレード、実行ポリシー変更をCodexが勝手に行わない。
復元時は管理台帳のmodule-versions.jsonで記録した版を優先し、既存版を無断で置き換えない。
既存のコマンドとパラメーターは導入版を確認してから使う。認証設定がなければ初期設定手順をユーザーに案内する。

## 接続処理の使い方

- 各操作スクリプトと同じプロセスで接続設定を読み、明示した許可済みサブスクリプションを選び、Connect-OpsApplicationで専用アプリの証明書認証を行う。既存の関数名・引数は維持する。
- 接続設定はLOCALAPPDATA\\AzureOpsSkills\\connection.json、証明書は登録したWindowsユーザーのCurrentUser\\Myストアに置く。秘密鍵を別ユーザーへ共有しない。
- 接続時・各API呼び出し前にAssert-OpsContextでテナント、サブスクリプション、アプリID、ServicePrincipal、AzureCloudを照合する。保存済み管理者接続や別プロセスの事前サインインを引き継いだと仮定しない。
- 呼び出し側は成功した接続をfinallyでDisconnect-AzAccount -Scope Processにより切断する。コンテキストの自動保存を無効にするが、OSや以前の認証キャッシュまで消す保証とは扱わない。
- ユーザーによる初期設定・PC登録・初回作成・権限付与解除はUser接続として明示した専用手順で行う。専用アプリの接続失敗を契機に自動で切り替えない。PIMは使用しない。
- 証明書が見つからない場合はwhoamiで実際のWindows実行ユーザーを確認する。環境変数だけで判断せず、証明書の再作成・移動・書き出し・秘密鍵ACL拡張で回避しない。
- トークン・秘密鍵・接続文字列・認証クレームや生レスポンスを出力・保存しない。DebugやTranscriptを記録に使わない。
- Get-InventoryReport.ps1は保存済みの整形結果を読むだけで、プロファイル読込・証明書確認・Azure接続を行わない。現在の権限や状態の確認には使わない。

## CodexからAzureを操作する実行方式

- ローカルの編集・構文確認・オフライン検証は通常の隔離環境で実行する。
- Azureへの読み取り・承認済み変更は、証明書を登録したWindowsユーザーの環境で実行する。別ユーザーの隔離環境と判明している場合は、失敗を再現せず、最初から実行ツールの正規の承認手続きを使う。Codexのexec_commandでは、対象と操作を明記した理由付きの `sandbox_permissions: require_escalated` を指定する。実行環境にこの機能がなければ、ユーザーに同じコマンドの実行を案内する。
- この承認はWindows側の実行境界を越える承認。Azureの認証主体は専用アプリのままで、接続時・各API呼び出し前のテナント、サブスクリプション、アプリID、認証種別の照合を維持する。Azure管理者へのサインインには切り替えない。
- 対象のスクリプトと引数をレビューし、そのコマンドに必要な範囲だけを要求する。PowerShell全体への包括的な許可、Full Accessへの切り替え、Sandboxアカウントへの証明書登録、秘密鍵の共有やアクセス権拡張を既定の解決策にしない。スクリプト自身から昇格・別ユーザー実行を起動しない。
- 承認が拒否された場合や、承認付きでも証明書・認証・ネットワークが利用できない場合は停止して理由を報告する。別経路・別アカウントで回避しない。承認の表示や自動審査は実行環境のポリシーに従い、必ず無確認で実行できるとは案内しない。
- 初回作成とロールの付与・解除は引き続きユーザーが実行する。実行境界の承認を、その作業の代行許可と解釈しない。

根拠: [CodexのSandboxと承認](https://learn.chatgpt.com/docs/sandboxing)、[Windowsの隔離方式](https://learn.chatgpt.com/docs/windows/windows-sandbox)、[Azure専用アプリの証明書認証](https://learn.microsoft.com/entra/identity-platform/howto-authenticate-service-principal-powershell)。

## ソースと配布先

ソースはリポジトリのscripts、配布先は各SKILL.mdの隣のscriptsを使う。Authentication.ps1はCommon.ps1と一緒に配布する。共通参照はソースのdocs/authentication.mdを配布先のreferences/authentication.mdへ配置する。初期設定・別PC登録の詳細は配布元リポジトリのdocs/setup.md・docs/recovery.mdにあり、これらはスキルには同梱しない。

## 本人サインインを伴う動作確認

Azure管理API・SCMの専用アプリによる証明書認証と、アプリ利用者本人の委任トークン・ブラウザーサインインは別の経路。
管理アプリの接続失敗を理由に本人や管理者へ切り替えない。本人操作が必要な業務要求は、案件の承認済み動作確認として分ける。
必要な既存モジュール・MSALの版と利用方法を確認し、共通スキルに案件で使用した版・UPN・クライアントIDを固定しない。
サインイン用コードは案件内ファイルへ保存し、短いpwsh -NoProfile -Fileコマンドと新規ログ保存先を先に示す。
トークンはメモリだけで使用し、キャッシュ・本文・認証ヘッダー・任意の例外文を保存しない。ユーザーの完了連絡後は事前指定したログを読んで続行する。

接続・環境の失敗時の停止は、失敗した経路と依存処理に適用する。許可済みの独立した読み取り・ローカル調査の継続条件はchange-workflow.mdの停止境界に従う。
