# 共通認証と実行環境

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
