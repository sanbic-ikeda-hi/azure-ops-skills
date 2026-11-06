# Sandboxでのスキル試験

この試験はリポジトリ版のサービス別スキルとヘルパーを使う。配布済みコピーの更新は別途ユーザーが行う。
初回作成・権限付与・解除はユーザーが実行し、専用アプリによる読み取り・承認済み変更は [共通手順](change-workflow.md) の正規の承認付き実行を使う。

## 作成するものと影響

| 項目 | 内容 |
| --- | --- |
| サブスクリプション | PC側の接続設定にあるsandboxSubscriptionIdのみ |
| 新規RG | rg-azureops-sandbox-test |
| Logic App | la-azureops-sandbox-test（Consumption） |
| リージョン | Japan East |
| 初期状態 | Disabled |
| 定義 | HTTP Requestトリガーと、固定文字列を出すComposeのみ |
| 関連リソース | App Serviceプラン、Storage、API接続、マネージドIDを作成しない |
| 権限 | この作成スクリプトは専用アプリに変更権限を付与しない |

Consumptionは実行回数等による従量課金で、無効状態のワークフローは課金対象外と公式資料に記載されている。今回の初回作成では実行を発生させない。後で有効化・実行した場合は、操作と実行履歴の保持に応じて課金対象となり得る。
定期トリガー・外部接続はない。コールバックURLやキーは取得・表示しない。
費用の根拠: [Logic Appsの課金](https://learn.microsoft.com/azure/logic-apps/logic-apps-pricing)。

## 1. ユーザーによる初回作成

PowerShell 7でリポジトリのルートから実行する。引数なしは計画表示だけで、Azureへ接続しない。

~~~powershell
pwsh -NoProfile -File .\scripts\New-SandboxLogicApp.ps1
~~~

計画を確認したら、ユーザーが次を実行する。サインイン画面では、SandboxでRG・Logic Appの作成権限を持つアカウントを選ぶ。

~~~powershell
pwsh -NoProfile -File .\scripts\New-SandboxLogicApp.ps1 -Create
~~~

この初回試験用スクリプトは新しいRGを用意する。同名RG・同名Logic Appがあれば停止し、既存を上書きしない。Microsoft.Logicが未登録なら自動登録せず停止する。
作成後はGETでID・Disabled・Succeededを照合し、許可された基本メタデータだけを表示する。
事前確認で停止した場合、この実行によるRG・Logic Appの作成は始まっていない。原因を解消してから作成を再開する。
作成開始後の失敗時は表示された段階で止める。RGなどが残る可能性があるため、再実行や自動削除をせず現状を確認する。
APIの根拠: [Workflows - Create Or Update](https://learn.microsoft.com/rest/api/logic/workflows/create-or-update?view=rest-logic-2019-05-01)。

### Microsoft.Logicの登録が必要な場合

登録はサブスクリプション側でLogic Appsを利用可能にする設定であり、専用アプリへのロール付与とは別。ユーザーがSandboxで登録権限を持つアカウントを使って実行する。作成スクリプトは自動登録しない。
次はSandboxのMicrosoft.Logicだけを登録する。登録の取り消しや他のプロバイダーの登録は行わない。

~~~powershell
. .\scripts\Common.ps1
$opsConnection = Read-OpsConnection
$opsTarget = Select-OpsSubscription $opsConnection $opsConnection.sandboxSubscriptionId
Disable-AzContextAutosave -Scope Process | Out-Null
try {
    Connect-AzAccount -Tenant $opsTarget.tenantId -Subscription $opsTarget.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    Assert-OpsContext (Get-AzContext) $opsTarget 'User'
    Register-AzResourceProvider -ProviderNamespace Microsoft.Logic -ErrorAction Stop |
        Select-Object ProviderNamespace, RegistrationState
} finally {
    Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
}
~~~

Registeredなら初回作成を再開できる。Registeringなら登録中なので登録操作を繰り返さず、上記の接続・照合・切断を保って登録コマンド部分を次の照会に置き換え、状態を確認する。認証・権限エラーはその場で止めて報告する。

~~~powershell
Get-AzResourceProvider -ListAvailable -ErrorAction Stop |
    Where-Object ProviderNamespace -EQ 'Microsoft.Logic' |
    Select-Object ProviderNamespace, RegistrationState
~~~
根拠: [プロバイダー登録エラーの解決](https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-register-resource-provider)、[Register-AzResourceProvider](https://learn.microsoft.com/powershell/module/az.resources/register-azresourceprovider)。

## 2. 作成後に行う試験

1. 専用アプリで一覧を再取得し、作成したConsumptionリソースの名前・完全なID・状態を確認する。ユーザー実行結果と独立した実取得を区別する。
2. キーワード `azureops` とRG名で絞り込み、候補番号とIDを対応させる。存在しないキーワードでも取得に成功し、一致件数だけが0になることを確認する。
3. 目的を「この試験用Logic Appの有効化と無効化」に限定して必要権限・影響を提案する。実際のAPI操作と範囲を確認し、ユーザー実行用の付与・解除コマンドを準備する。
4. ユーザーの付与後、専用アプリで承認済みの状態変更と再取得を行い、最後はDisabledに戻す。HTTPトリガーを呼び出す実行試験は別途目的・費用を確認する。
5. 今回追加した割当だけをユーザーが解除し、解除結果を確認する。認証・権限エラーを使った変更コマンドの自動反復試験は行わない。

変更に進む前に、対象・目的・API操作・戻し方が確定していることが必要。今回の一連の試験依頼で明確な情報は聞き直さない。

### 今回の状態変更に必要な権限

Grantで権限を受け取るのは、接続設定のapplicationIdに対応するEntraのサービスプリンシパル（エンタープライズアプリ）。割当先はservicePrincipalObjectIdで照合する。実行するユーザーが、この専用アプリへAzure RBACロールを割り当てる。Entraの「APIのアクセス許可」を追加する操作ではなく、WindowsのSandboxユーザーや特定のチャットに権限を付ける操作でもない。同じ専用アプリとして認証する別PC・別プロセスも、その権限を利用できる。
実行を案内するメッセージには、ローカル設定で確認した付与先ApplicationId・サービスプリンシパルObjectId・完全なScopeを示し、以下の操作と解除条件を日本語で説明する。実環境のIDはこの文書には保存しない。

対象は上記の試験用Consumptionワークフロー1件。DisabledからEnabledにし、GETで確認後にDisabledへ戻す。HTTPトリガーは呼び出さず、定義・接続先も変更しない。作成した定義はHTTP Requestと固定文字列のComposeだけだが、有効化前に現在の定義と依存先が変わっていないことを確認する。有効中はHTTPリクエストを受け付け得るため、試験後は無効化を確認する。

既存の読み取りロールに加え、次の2操作だけをカスタムロールで追加する。APIは2019-05-01のPOST `/enable` とPOST `/disable`。読み取りは既存の `Microsoft.Logic/workflows/read` を使う。

| 追加するAzure RBAC操作 | 許可する内容と試験での用途 |
| --- | --- |
| `Microsoft.Logic/workflows/enable/action` | このワークフローを有効にする。DisabledからEnabledへ切り替える試験に使う |
| `Microsoft.Logic/workflows/disable/action` | このワークフローを無効にする。試験後にDisabledへ戻すために使う |

実際のロール割当Scopeはワークフローの完全なID。AssignableScopesは試験RGで、ロールを割当可能にする範囲を表す。RGへのアクセス付与ではない。この追加ロールには定義変更・実行開始・秘密取得・削除・RBAC管理を含めない。他ロールによる権限は合算されるため、スクリプトが表示する既存・継承割当の情報も確認する。追加ロールだけで専用アプリの全有効権限を保証しない。

ユーザー実行用の `scripts/Set-SandboxLogicAppAccess.ps1` は、引数なしなら接続せず計画を表示する。初回作成スクリプトの既定名の試験リソースだけを対象とする。別名で作った場合は、そのまま実行せず対象に合わせた案を準備する。

~~~powershell
pwsh -NoProfile -File .\scripts\Set-SandboxLogicAppAccess.ps1
pwsh -NoProfile -File .\scripts\Set-SandboxLogicAppAccess.ps1 -Action Grant
~~~

Grantはユーザーがロール定義・割当を管理できるアカウントで実行する。対象・接続先・専用アプリObjectId・既存ロールの内容を照合し、既存ロールを更新しない。既に同じロールの割当があれば停止する。出力のAssignmentIdを保持し、途中失敗時は自動再実行せず表示された段階と現在の割当を確認する。ロール定義だけが残る場合もある。
このスクリプトのGrantはロール定義と割当を設定し、Logic Appの状態は変更しない。期限付き割当ではなく、自動失効しない。PowerShellやチャットを終了しても、ユーザーがRevokeを実行するまで割当は残る。

付与後に専用アプリで状態変更試験を行い、Disabledに戻ったことを確認してから、ユーザーが出力されたAssignmentIdを指定して解除する。

~~~powershell
pwsh -NoProfile -File .\scripts\Set-SandboxLogicAppAccess.ps1 -Action Revoke -AssignmentId '<Grantが出力したAssignmentId>'
~~~

Revokeはその割当ID・ObjectId・RoleId・Scopeを照合した1件だけを解除し、再取得で不存在を確認する。常設の読み取り割当とロール定義は残す。割当の不存在と実効権限への反映は別で、Azure側の反映待ちがあり得る。

公式根拠: [Microsoft.Logicの操作一覧](https://learn.microsoft.com/azure/role-based-access-control/permissions/integration#microsoftlogic)、[Enable API](https://learn.microsoft.com/rest/api/logic/workflows/enable?view=rest-logic-2019-05-01)、[Disable API](https://learn.microsoft.com/rest/api/logic/workflows/disable?view=rest-logic-2019-05-01)、[New-AzRoleDefinition](https://learn.microsoft.com/powershell/module/az.resources/new-azroledefinition)、[Remove-AzRoleAssignment](https://learn.microsoft.com/powershell/module/az.resources/remove-azroleassignment)。

### 今回表示された仕様変更予告

Az.Resources 10.2.2環境のGet-AzRoleDefinition／New-AzRoleDefinitionで、PSRoleDefinitionの直下にあるActions等からPermissions配列へ移行する旨の「Upcoming breaking changes」が表示された。スクリプトは既にPermissions[0].Actions等を参照し、作成時もPermissions配列を渡している。この予告に対する追加修正は不要で、予告が表示されたこと自体を操作失敗と扱わない。実行結果と取得による確認を別に判断する。
この判断は今回の予告だけが対象。権限不足、認証失敗、取得失敗などの警告・エラーを一括で無視しない。警告抑止の設定変更は実施していない。
根拠: [Get-AzRoleDefinitionのPermissions形式](https://learn.microsoft.com/powershell/module/az.resources/get-azroledefinition)、[New-AzRoleDefinitionのPermissions形式](https://learn.microsoft.com/powershell/module/az.resources/new-azroledefinition)。

## 確認記録

- 2026-11-06: 通常隔離環境は別のWindows実行ユーザーで、利用者のCurrentUser証明書が見えないことを確認。環境変数だけでは実行主体を判別できなかった。
- ユーザー提供結果: 対象のユーザー証明書に秘密鍵があり、有効期間内。
- 独立した実取得（同日19:05 JST）: 正規の承認付き実行で専用アプリの接続に成功。SandboxのLogic Apps一覧はComplete=true、TotalCount=0、Count=0。
- 独立した実取得（同日19:17 JST）: 改訂手順どおり最初から承認付きで、RG名とキーワードを指定して取得成功。Complete=true、TotalCount=0、Count=0。この時点はリソース作成前。
- オフライン: 257項目成功。作成処理の計画・事前停止・無効状態の定義・作成後照合・再試行防止に加え、権限付与の対象限定、余分な操作を持つ既存ロールの拒否、既存割当の保護、指定IDだけの解除と解除確認失敗時の停止を模擬接続で検証。Az.Resources 10.2.2の実際の型でもPermissions構造をローカル検証した。
- ユーザー提供結果（同日）: 初回作成はMicrosoft.Logicの登録確認でNotStartedのまま停止。スクリプト上のRG・Logic App作成より前であり、この実行による作成はない。登録状態を詳細表示し、事前確認での停止と部分作成を警告文で区別するよう改善した。
- ユーザー提供結果（同日）: プロバイダー登録後の初回作成が成功。試験用ConsumptionワークフローはDisabled・Succeeded。この時点では専用アプリへの変更権限は未付与。
- 独立した実取得（同日19:35 JST）: 専用アプリでRG名とキーワードazureopsを指定し、Complete=true、TotalCount=1、Count=1。完全な対象IDとDisabled・Succeededを照合。存在しない検索語ではComplete=true、TotalCount=1、Count=0を確認。対象が明確なため選択の聞き直しは行わない。
- ユーザー提供結果（同日）: Grantが成功。専用アプリに有効化・無効化の2操作を持つカスタムロールを作成し、試験用ワークフロー1件だけに割り当てた。出力にあるサブスクリプション範囲の割当は既存の読み取り割当で、新規の変更権限割当とは別。
- 実地試験の直前確認（同日19:54 JST）: ユーザーが今回の現行方式での実行を明示的に了承。正規の承認付き実行でWindows主体が証明書所有ユーザー、Azure主体が専用アプリのServicePrincipalであることを確認。完全な対象ID・Disabled・Succeededと、HTTP Request＋固定Composeの定義の完全一致、外部接続・マネージドIDなしを照合した。生定義やURLは出力していない。
- 独立した実変更・再取得（同日19:55 JST）: 専用アプリでPOST enableを1回実行しHTTP 200・EnabledをGETで確認。その後POST disableを1回実行しHTTP 200・DisabledをGETで確認。両操作後とも定義は変化なし。HTTPトリガーの呼び出し・定義変更・削除・権限操作・変更の再試行は実施していない。
- ユーザー提供結果（同日）: Revokeが成功し、今回のAssignmentIdに対してAssignmentAbsent=trueを確認。対象の割当は解除済み。カスタムロール定義と既存読み取り割当は維持する。これはユーザー実行結果であり、Codexが管理者接続で割当を独立再取得した結果ではない。
- 独立した実取得（同日20:01 JST）: 解除後に専用アプリで同じRG名・キーワード検索を実施し、Complete=true、TotalCount=1、Count=1、Disabled・Succeededを確認。既存の読み取りが継続できることを確認した。拒否されることを確認する目的の変更操作は行っておらず、他の割当も含む全実効権限を監査済みとは扱わない。
- 今回のConsumption試験は、ユーザーによる作成・権限付与解除と、Codexによる取得・検索・有効化・無効化・最終読み取りまで完了。試験用リソースとロール定義は残している。配布済みスキルの更新、他サービスの実リソース変更、本番での検証はこの結果に含めない。

## 今後の課題：サンドボックスユーザーでの実行

2026-11-06のユーザー指示により、Codexがスクリプトを実行し、ユーザーは内容確認と承認を行う運用を今後検討する。その案ではWindowsのサンドボックスユーザーでの実行を条件とする。今回の試験は現行の承認付き実行で継続し、この案の実装・設定変更は行わない。

- 現状確認: 通常実行のwhoamiはcodexsandboxoffline。PowerShell 7.6.9、ConstrainedLanguage。コンピューター領域のAz.Accounts 5.5.4／Az.Resources 10.2.2は参照できるが、今回の証明書はそのCurrentUserストアから参照できない。モジュールが使えることと、専用アプリとして認証できることを区別する。
- 検討事項: Codexが管理する実行ユーザーと証明書の扱い、必要な通信、実行承認とWindows主体の関係を公式にサポートされた方式で調べる。証明書のコピー・Sandboxアカウントへの登録・秘密鍵ACL緩和を既定の回避策にしない。
- 権限の境界: 状態変更を行う専用アプリと、初回作成・RBAC付与解除を行う管理ユーザーのAzure認証を分離する。専用アプリ自身に権限管理を付与せず、スクリプトの説明・個別Scope・実行前の本人確認を保つ。
- 現行ルール: 初回作成とRBAC付与解除はユーザー実行のまま。将来の実行代行は方針・認証方式を具体化してから合意する。
- PIM: ユーザー申告で対象ライセンスがないため採用しない。時限付与は実装せず、今回の通常割当は明示的に解除する。

## App Service：既存プランへの追加と既存Web Appの変更

2026-11-06の追加依頼。無料には限定せず、短時間で数千円に達しない構成で試す。本番の利用形態に合わせ、プラン作成と、その既存プランへのWeb App追加を分けて検証する。

新規プランの自動スクリプトによる作成は保留している。東南アジアでもP0v4の作成時クォータ上限0で失敗した。下記のプラン作成コマンドは、照会APIの上限30との不一致を解決するまで再実行しない。他リージョン・SKUへの連続試行も行わない。その後ユーザーが手動で作成したWest US 3のWindowsプランに試験対象を切り替えた。現在の手順は末尾の「手動作成プランへのWeb App追加」を参照する。

| 項目 | 試験対象 |
| --- | --- |
| サブスクリプション | PC側のsandboxSubscriptionId |
| 新規RG | rg-azureops-appservice-test-southeastasia（Japan East・Logic Appsの試験RGとは別） |
| 試験用プラン | asp-azureops-sandbox-test-southeastasia、Southeast Asia、Linux P0v4、1インスタンス |
| Web App | app-azureops-test- に専用アプリIDのハイフンを除いた先頭12文字と -southeastasia を付ける |
| 公開・依存関係 | publicNetworkAccess=Disabled、HTTPSのみ、コード配置・外部接続・Storage・監視リソース・マネージドIDなし |
| 実行主体 | 初回作成・権限付与解除・後片付けはユーザー、以後の読み取りと承認済み変更は専用アプリ |

### 費用と後片付け

同日取得した[Azure公式料金API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)では、Southeast Asia / Azure App Service Premium v4 Plan - Linux / P0v4 / Consumption / JPYの参考価格は15.016円/時。2時間で約30円、24時間で約360円のプラン料金の目安。Japan Eastの同SKUは16.7724円/時だった。円価格は見積用で、契約・為替・税等による実請求との差がある。契約上の上限や自動停止を設定したものではない。
最初はB1を計画したが、ユーザーの追加指示により本番と同じLinux Premium v4の最小SKUを試験する。既定値はP0v4。互換性のため-Sku B1も指定できるが、エラー時に自動でSKUを切り替えない。Japan EastのP0v4も実試験でクォータ上限0により失敗したため、海外候補のユーザー提供結果に基づきSoutheast Asiaを第一候補とする。価格掲載や正のクォータは、実際の作成成功・物理容量を保証しない。
試験は作成から数時間以内に終了し、不要になったWeb Appとプランをその場で削除する。アプリ停止・アプリだけの削除ではプランの課金は止まらない。[公式の課金説明](https://learn.microsoft.com/azure/app-service/overview-manage-costs#understand-the-full-billing-model)。

### ユーザーによる準備

`Set-SandboxAppServiceFixture.ps1` はこの試験だけのユーザー実行用スクリプトで、配布するスキルに同梱しない。引数なしはローカルの計画表示のみ。-Locationはjapaneast（互換性のため既定値）、southeastasia、westus2、centralusに対応。Japan East以外ではRG・プラン・アプリ名にリージョン名を付け、既存の日本側試験と分ける。作成・追加・後片付けのすべてで同じ-Locationと-Skuを指定する。

~~~powershell
pwsh -NoProfile -File .\scripts\Set-SandboxAppServiceFixture.ps1 -Location southeastasia -Sku P0v4
# 先に試験用プランを1つ用意する。新規RG限定。同名RGがあれば停止。
pwsh -NoProfile -File .\scripts\Set-SandboxAppServiceFixture.ps1 -Action CreatePlan -Location southeastasia -Sku P0v4
# 作成が成功してから、既存プランへWeb Appだけを追加する。
if ($LASTEXITCODE -eq 0) {
    pwsh -NoProfile -File .\scripts\Set-SandboxAppServiceFixture.ps1 -Action AddApp -Location southeastasia -Sku P0v4
}
~~~

ユーザーがSandboxのリソース作成権限を持つアカウントでサインインする。これらの操作は専用Entraアプリにロールを付与せず、Entra APIのアクセス許可も変更しない。専用アプリの変更権限は、作成後に別途説明して個別リソースへ付与する。
CreatePlanはMicrosoft.WebがRegisteredでなければ停止する。自動登録・別SKUへの切替はしない。AddAppは既存プランのID・試験タグ・Linux・指定SKU・1台・Readyを確認し、Web AppへのPUTだけを行う。プランのPUT/PATCHは行わない。GETによる作成完了待ちは最大3分。書き込みエラーは再試行せず、残ったプランの費用と片付けを確認する。

### 部分作成からの明示的な再開

現在の方針: ユーザーはSandboxでの増枠申請を保留し、日本以外も含めて作成可能な枠を探すことを指定した。次の申請・再開手順はJapan Eastを使う場合の条件付き手順で、今すぐの実行依頼ではない。作成失敗が確認できたのはJapan EastのB1とP0v4であり、他のSKU・リージョンまで作成不可とは断定しない。
ユーザー実行用Get-AppServiceQuota.ps1で海外6候補を取得した結果を、同日20:59 JST取得のファイルで確認した（Complete=true）。専用アプリへ照会権限は追加していない。westus2・centralus・southeastasiaではP0v4と項目名「*」がいずれも使用数0・上限30だった。eastus・northeuropeはP0v4が30でも「*」が0、westeuropeは「*」のみでP0v4が未掲載のため、同じ条件の候補には含めない。ユーザー提供結果であり、Codexが独立した認証で取得した値ではない。生レスポンス・実環境IDは保存しない。
Southeast AsiaのLinux P0v4の公式参考価格を確認し、Fixtureを明示的なリージョン指定と地域別の名前に対応させた。その後、ユーザーによる作成はクォータ上限0で失敗した。照会値30だけでは、作成時に有効な枠を確認できなかった。Portalで同じ対象の表示を照合するまで作成を保留する。失敗時に候補地域へ順次作成を繰り返さず、返されたエラーから判断する。

今回のB1試験では、Registeredの確認とRG作成の後、プランのPUTがHTTP 401で失敗した。ユーザー提供のアクティビティログのエラー本文からB1 VMsのクォータ上限0・使用数0・必要数1・要求上限1・拡張コード70007を確認。認証エラーや登録の反映待ちではなく、クォータ不足が原因だった。専用アプリによる独立したGETではRGがSucceeded、プランとWeb AppはHTTP 404だった。生ログ・caller・claimsは記録しない。

ユーザーは本番に合わせたLinux P0v4の試験を指定したため、B1の増枠申請は行わず、同じRGで未作成のプランから再開した。そのP0v4も上限0で失敗したため、以後は増枠が反映されるまで以下を再実行しない。

ユーザーがAzure PortalのQuotas → App Service (Public Preview)でSandbox・Japan East・P0v4 VMsを選び、新しい上限を1として申請する。SKUとTotal Regional VMsの両方に枠が必要だが、Total Regional VMsへの直接申請ではなく個別SKUの増枠を申請する。地域合計が0/0で個別SKUが表示されない場合は、今回の失敗結果を添えてサポートへ申請する。承認だけでなく画面上の上限反映も確認する。専用アプリへのRBAC付与とは別の設定であり、Codexは申請・権限変更を代行しない。

~~~powershell
pwsh -NoProfile -File .\scripts\Set-SandboxAppServiceFixture.ps1 -Action ResumePlan -Sku P0v4
if ($LASTEXITCODE -eq 0) {
    pwsh -NoProfile -File .\scripts\Set-SandboxAppServiceFixture.ps1 -Action AddApp -Sku P0v4
}
~~~

ResumePlanは試験用RGの名前・タグ・リージョン、プランが存在しないこと、RGが空であることを確認してからプランだけを作成する。既存プランの更新・RGの再作成・他リソースの変更・削除は行わない。P0v4もクォータ不足なら別SKUへ繰り返さず停止し、返された構造化エラーに基づいて判断する。クォータは[サブスクリプション・リージョン・展開方式・SKUごと](https://learn.microsoft.com/troubleshoot/azure/app-service/troubleshoot-non-zone-redundant-quota-requests)に確認する。

### Microsoft.Webの登録が必要な場合

PreflightでMicrosoft.Webの登録確認により停止した場合、その実行ではRG・プラン・Web Appの作成は始まっていない。後続のAddAppも前の終了コードが0のときだけ実行する。削除による片付けは不要。

SandboxサブスクリプションでApp Serviceを利用可能にする登録を、ユーザーが行う。専用EntraアプリへのAzure RBAC付与とは別で、この操作では専用アプリに変更権限を追加しない。実行ユーザーにはMicrosoft.Web/register/actionが必要（Contributor/Ownerに含まれる）。Azureの仕様としてプロバイダー用のMicrosoft管理アプリがEntraに追加される場合がある。

Azure Portalでは、サブスクリプションのSandbox → 設定 → リソースプロバイダー → Microsoft.Web → 登録。PowerShellでは次を使う。接続先はPC側のSandbox設定で照合する。

~~~powershell
$ErrorActionPreference = 'Stop'
. .\scripts\Common.ps1
$opsConnection = Read-OpsConnection
$opsTarget = Select-OpsSubscription $opsConnection $opsConnection.sandboxSubscriptionId
Disable-AzContextAutosave -Scope Process | Out-Null
try {
    Connect-AzAccount -Tenant $opsTarget.tenantId -Subscription $opsTarget.subscriptionId -Scope Process -ErrorAction Stop | Out-Null
    Assert-OpsContext (Get-AzContext) $opsTarget 'User'
    Register-AzResourceProvider -ProviderNamespace Microsoft.Web -ErrorAction Stop |
        Select-Object ProviderNamespace, RegistrationState
} finally {
    Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
}
~~~

Registeringなら登録中なので登録コマンドを繰り返さない。状態照会は上記の接続・照合・切断を保ち、Register-AzResourceProvider部分だけを次に置き換える。

~~~powershell
Get-AzResourceProvider -ListAvailable -ErrorAction Stop |
    Where-Object ProviderNamespace -EQ 'Microsoft.Web' |
    Select-Object ProviderNamespace, RegistrationState
~~~

今回の試験スクリプトはRegisteredを確認してからCreatePlanを再開する。これは試験の事前確認の条件であり、Azure全般でRegistering中の作成が禁止されるという意味ではない。Azureでは対象リージョンの登録が完了すれば、全体がRegisteringでも作成可能。
根拠: [プロバイダー登録・必要権限・登録中の扱い](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types#register-resource-provider)、[Register-AzResourceProvider](https://learn.microsoft.com/powershell/module/az.resources/register-azresourceprovider)。

### 作成後の実地検証

1. 専用アプリで一覧・RG/キーワード検索・基本設定を取得し、完全なWeb App IDと既存プランの関連を確認する。
2. 目的を起動・停止と、clientAffinityEnabled（セッション固定）の変更・復元に限定して説明する。開始前に元の値をGETする。
3. 提案する追加ActionsはMicrosoft.Web/sites/start/action、Microsoft.Web/sites/stop/action、Microsoft.Web/sites/write。DataActionsなし。割当Scopeは作成したWeb Appの完全なIDだけ。既存の読み取りと加算される。sites/writeはセッション固定だけに制限された権限ではなく、対象Web Appの他の構成更新も許可する。プランの更新・削除・RBAC管理・秘密取得の操作は追加しない。自動失効しないため終了後に今回のAssignmentIdを指定してユーザーが解除する。
4. 権限付与コマンドの実行依頼時には、実際のApplicationId・サービスプリンシパルObjectId・テナント・サブスクリプション・Scopeと、上記の意味・影響を本文でも説明する。作成スクリプトの実行は権限付与を意味しない。
5. 専用アプリで起動・停止・設定変更・復元を行い、それぞれGETで検証する。publicNetworkAccess=Disabled、httpsOnly=trueを維持する。プランのID・SKU・台数も前後比較する。
6. ユーザーが今回追加した割当を解除したら、次のRemoveをユーザーが実行する。途中で試験を中止した場合も作成済みのプランを残さないよう確認する。

~~~powershell
pwsh -NoProfile -File .\scripts\Set-SandboxAppServiceFixture.ps1 -Action Remove -Location southeastasia -Sku P0v4
~~~

Removeは指定リージョンの試験用Web Appと試験用プランだけを削除する。削除前にID・試験タグ・RGと各リソースのリージョン・指定SKU/1台・他リソースの有無・プランのアプリ数を確認する。アプリ削除時のプラン自動削除を明示的に無効化し、アプリの不存在とプランが空であることを確認してからプランを削除する。試験タグやリージョンが異なる、他リソースや共有アプリがある、ロック・権限エラー等の場合は停止する。自動ロック解除・強制削除・書き込み再試行は行わない。既定値はP0v4なので、明示的にB1を作成した場合はRemoveにも-Sku B1を付ける。
空のRGとカスタムロール定義は残す。アプリやプランの削除成功だけでロール割当を明示的に解除済みとは扱わない。最終確認はAppAbsent=true、PlanAbsent=true。どちらかを確認できなければ課金停止済みと報告しない。

API根拠: [プラン作成](https://learn.microsoft.com/rest/api/appservice/app-service-plans/create-or-update?view=rest-appservice-2024-11-01)、[Web App作成](https://learn.microsoft.com/rest/api/appservice/web-apps/create-or-update?view=rest-appservice-2024-11-01)、[Web App削除](https://learn.microsoft.com/rest/api/appservice/web-apps/delete?view=rest-appservice-2024-11-01)、[プラン削除](https://learn.microsoft.com/rest/api/appservice/app-service-plans/delete?view=rest-appservice-2024-11-01)。

### 追加テストの記録

- 全オフライン検証: 968項目成功（一覧結合117、App Service試験環境243、エラー診断22、クォータ照会42、Web App権限48、既存プランへのWeb App作成99、操作試験とレポート82、既存検証と配布・構文等315）。変更に関係するテストを先に実行し、各スクリプト変更作業の最後にTest-Repository.ps1を1回実行した。
- 独立した実取得（2026-11-06 20:11 JST）: 専用アプリでSandboxのAppServiceとFunctionsを取得し、両方Complete=true、TotalCount=0、Count=0を確認。存在するFunctionsの変更やApp Serviceの作成は未実施。
- オフライン一覧結合テスト: サービス判別、全ページ取得後の検索、0件と1件の配列、HTTPエラー・循環/外部リンク・別サブスクリプション・認証主体不一致・証明書不正を確認。不正なvalue=nullを成功とする問題を再現し、配列以外を拒否するよう修正。接続成功直後の主体照合に失敗した場合も切断するよう修正。
- オフライン試験環境テスト: 新規プラン、既存プランへの追加、同名/別プラン/別主体の拒否、非同期作成、エラー時の書き込み非再試行、共有プラン・他リソースの削除拒否、個別削除順序をモックで検証。実リソース作成・実課金・実削除を確認した結果ではない。
- リージョン指定のオフライン試験: 従来のJapan Eastの既定対象を保持し、海外用の名前・RG/PUTのリージョン・計画表示が一致すること、別リージョンのRG/リソースを追加・削除の対象にしないことを確認。Southeast Asiaでは作成・再開・既存プランへの追加・限定削除をモックで確認した。
- 配布先のコピーは更新しない。スキルの対話・権限相談は手順レビューと実地の会話で確認し、PowerShellの模擬試験だけで自由な対話全般を保証しない。
- 配布元とのハッシュ比較では、配置済み3スキルで各SKILL.md・2ヘルパーが相違（計9件）、各references/change-workflow.mdが未配置（計3件）。配布元の参照先と新規配布時の構成は検証済みだが、配置済みコピーに最新の参照が揃っているとは扱わない。
- ユーザー環境の接続設定を用いたPlanモードの実行を確認。Azureへの認証・作成はせず、Sandbox内の専用RG・プラン・Web Appと権限付与なしの計画を出力した。
- ユーザー提供結果（2026-11-06）: CreatePlanはMicrosoft.Webの登録確認でPreflight停止。元のメッセージだけでは未登録と登録中を区別できないが、この実行で作成処理は始まっていない。後続AddAppも終了コードにより未実行。登録状態の表示、登録手順への案内、変更前の停止と部分作成を区別する警告を追加した。実登録・実作成の成功はまだ未確認。
- ユーザー提供結果と添付ログ（同日20:43 JST）: ResumePlan / P0v4もHTTP 401・Unauthorized・拡張コード70007で失敗。P0v4 VMsの上限0・使用数0・必要数1・最低要求上限1を確認。新しいエラー要約は生のmessageを出さず、Quota判定と数値を出力できた。後続AddAppは未実行。独立した専用アプリのGETでも、失敗後のプラン・Web Appはいずれも404だった。作成の再試行・別SKUへの変更は止め、P0v4の増枠反映を待つ。添付の生ログ・認証クレームはリポジトリへ保存していない。

- ユーザー提供ログ（同日21:09 JST）: Southeast Asiaの試験プラン作成がHTTP 401・Unauthorized・拡張コード70007で失敗。エラーの対象枠はP0v4 App Service instances、上限0・使用数0・必要数1・最低要求上限1。同じサブスクリプションの20:59 JST照会ではsoutheastasiaのP0v4が上限30だったため、照会値と作成時の制限が食い違っている。対象IDは東南アジア用であり、リージョン名の取り違えではない。不一致の原因は未特定。OS別枠・反映遅延・Azure側の不整合などを事実として断定しない。
- 独立した実取得（同日21:12 JST）: 専用アプリで東南アジアの試験プランとWeb Appを個別GETし、両方HTTP 404を確認。作成済みのプラン・Web Appは残っていない。削除・再作成・権限変更はしていない。
- 上記を受けて共通の作成失敗手順へ「照会値と作成エラーが矛盾したら、作成可否を未確認として保留する」を追記。スクリプトは推測で変更せず、今回は文書のみ更新したためオフライン検証を再実行していない。配置済みスキルは未更新。

実環境ID・証明書情報・Azureの生レスポンスはこの記録に保存しない。

## 手動作成プランへのWeb App追加

2026-11-06、ユーザーが手動作成したプランを指定し、Web Appの作成試験も行うよう再確認した。専用アプリによる独立GETでは、West US 3・Windows（reserved=false）・P0v4・1台・Succeeded/Ready、同居Web Appが1件あることを確認。RG名に含まれる地域とプランの実所在地は異なるため、プラン自身のlocationを使う。これはWindowsでの試験であり、当初のLinuxプラン作成を検証済みとはしない。先のクォータ照会値と作成時の制限の不一致も解決済みとはしない。

既存Web Appの初期状態はRunning、clientAffinityEnabled=true、httpsOnly=true、publicNetworkAccess=Enabled。まず既存プランへ別の試験用Web Appを1件追加し、その新しいアプリで起動・停止・セッション固定の変更/復元を試す。手動作成された同居アプリとプランは前後比較の対象とする。サイト設定やコード、秘密情報の取得は行わない。

### ユーザー実行用スクリプト

- `scripts/New-SandboxWebApp.ps1`: 完全なResourceId・PlanResourceIdとExpectedLocation・ExpectedOperatingSystem・ExpectedSkuを指定する。既定はローカルのPlan表示。-Action Createは既存RGと既存プランをGETで照合し、同名アプリがなければWeb Appだけを1回PUTする。新規プランやRGを作らず、RGの所在地とプランの所在地の一致を要求しない。対応する試験用SKUはB1/P0v4・1台、OSはWindows/Linux。
- 追加アプリはpublicNetworkAccess=Disabled、httpsOnly=true、clientAffinityEnabled=false、FTPS無効・最小TLS1.2、コード配置・外部接続・マネージドIDなし。既存プランのCPU・メモリを共有する。SKU・台数を増やさないが、既存プランの課金は続く。作成後はアプリのplan ID・OS・所在地・公開設定とプランの構成をGETで検証する。
- `scripts/Set-SandboxAppServiceAccess.ps1`: 完全なResourceId・PlanResourceIdを指定する。既定はPlan表示。GrantはRunningのWeb Appと期待するプランの関連・準備完了、EntraサービスプリンシパルのIDを確認してから、対象アプリだけにカスタムロールを割り当てる。ActionsはMicrosoft.Web/sites/start/action、stop/action、writeの3件。DataActionsなし。AssignableScopesはアプリのRGだが、実際の割当Scopeは個別アプリIDのみ。
- sites/writeはセッション固定だけに限定された権限ではなく、そのWeb Appの他の構成更新も可能。プラン更新・削除・秘密取得・RBAC管理は追加しない。既存ロールと加算される。Entra API権限ではなく専用アプリのサービスプリンシパルへのAzure RBACであり、同じアプリとして認証できる他のプロセスにも適用される。
- RevokeはGrantで出力された完全なAssignmentIdを必須とし、アプリ・主体・ロール・割当IDを照合してその1件だけを削除する。自動失効なし。元のReaderとロール定義は残す。Revoke自体はアプリやプランのGETに依存しない。
- 両スクリプトともPC側のsandboxSubscriptionIdに限定する。ユーザーの明示的なサインインで動き、Codexによる管理者認証への切り替えには使わない。書き込み失敗は再試行せず、部分作成やロール定義だけが残る可能性を報告する。実環境IDは引数で渡し、ソースへ固定しない。試験用ヘルパーとしてリポジトリに保存し、配布済みスキルやInstall-Skillsの配布対象は変更しない。

### 実地試験の順序と後片付け

1. ユーザーがNew-SandboxWebAppのCreateを実行し、成功時に追加アプリだけのGrantを実行する。権限付与の説明は共通手順に従い、実際の各ID・Scopeと操作の広さを本文で提示する。
2. 専用アプリで追加アプリと同居アプリの一覧・検索・プロパティ、プランのSKU・台数を取得する。
3. 追加アプリを停止→GET Stopped→起動→GET Running。続いてclientAffinityEnabledをfalse→true→falseと変更し各段階をGET確認する。HTTPS・公開アクセス・プランとの関連を維持し、同居アプリとプランの前後も比較する。HTTPコンテンツやコードの機能試験とは区別する。
4. ユーザーが今回のAssignmentIdを使ってRevokeし、今回の割当だけが消えたことを確認する。
5. 追加アプリ、手動作成の試験アプリ、最後に空になった手動作成プランをユーザーが個別に削除し、各IDの不存在を確認する。旧Set-SandboxAppServiceFixtureのRemoveは固定名・タグ・Linuxを前提とするため、この手動プランの削除には使わない。新しい作成・RBACヘルパーにリソース削除機能は入れない。

### 検証状況

- ユーザー提供結果: New-SandboxWebAppによる追加アプリの作成、プラン構成の照合、追加アプリ1件へのカスタムロール割当の成功を確認。既存のReader割当が別に残っている。実環境IDや生出力はリポジトリへ保存していない。
- 独立した実操作（2026-11-06 21:41～21:42 JST）: 専用アプリの証明書認証で、追加アプリのRunning→Stopped→Running、clientAffinityEnabled=false→true→falseを実行し、各段階をGETで確認。HTTPSのみ・公開アクセス無効と既存プランへの関連を維持した。最終状態は元のRunning/false。
- 同居アプリの比較対象（状態・セッション固定・HTTPS・公開アクセス・プランID・kind・所在地）は変化なし。プランの比較対象（所在地・OS・SKU/tier・1台・アプリ数2・perSiteScaling・zoneRedundant）も変化なし。全設定・アプリコード・HTTPコンテンツや性能を検証した結果ではない。
- ユーザー提供結果（2026-11-06 21:46 JST）: Revokeの保存テキストから、今回の追加アプリだけに付与した割当IDの削除とAssignmentAbsent=trueを確認。既存Reader割当とカスタムロール定義は残る。独立したRBAC照会や、拒否確認のための変更要求は実施していない。
- 独立した実取得（同日21:51 JST）: 解除後も専用アプリの証明書認証で2つのWeb AppとプランをGETできた。追加アプリはRunning・セッション固定false・HTTPSのみ・公開アクセス無効、同居アプリはRunning・セッション固定true・HTTPSのみ・公開アクセス有効で、試験終了時の比較対象プロパティを維持。プランはWest US 3・Windows・P0v4・1台・アプリ数2・Succeeded/Ready。選択した非秘密項目だけをTEMPのUTF-8テキストへ保存し、読み直した。
- ユーザーからWeb App 2件と手動作成プランの削除報告を受領。同日22:16 JSTに専用アプリで各IDを個別GETし、全3件のHTTP 404を独立確認した。このApp Service試験の操作・復元・一時権限解除・リソースの後片付けは完了。実際の請求額・課金履歴は取得していない。
- オフライン99項目: Windows/Linux、RG所在地がプランと違う場合、既存アプリ非上書き、OS/地域/SKU/台数不一致、途中の認証先変更、部分作成後の失敗、GET待機、プランへの非書き込みと構成比較、公開設定の照合を確認。
- オフライン48項目: 個別Scope、プランとの関連、既存ロールの厳密照合、DataActionsや広いAssignableScopesの拒否、他サブスクリプション・スロット・Functionsの拒否、割当1件だけの解除、失敗時の非再試行を確認。
- 実際の接続設定で両ヘルパーのPlan表示を確認。Azureへの作成・権限付与は実行していない。
- 操作試験にはInvoke-SandboxWebAppTest.ps1を追加。既定は計画表示・保存だけで、-Executeを明示した場合だけ実操作する。対象・比較対象・プラン・ユーザー提供のAssignmentIdと新規OutputPathを必須とする。現在は今回のWindows/West US 3/P0v4/1台・Running/セッション固定false/公開無効の条件に限定し、別の構成を勝手に試さない。
- オフライン82項目: 4つの承認済み変更の順序、各段階のGET確認、失敗時の非再試行、元の状態への復元、同居アプリ/プランの比較、専用アプリ照合、秘密を含む模擬フィールドの非記録、既存レポート・リポジトリ内出力の拒否、出力失敗時の変更前停止を確認。
- 実操作の記録はユーザーのTEMPにUTF-8テキスト（1行1JSON）で保存し、Plan/Baseline、4段階のVerified、Final/Succeededをファイルから読み直して確認した。実際のファイル名・各リソースIDは会話で案内し、Gitには含めない。今回からファイルパスだけで結果を渡せる運用とする。

公式根拠: [Web App作成](https://learn.microsoft.com/rest/api/appservice/web-apps/create-or-update?view=rest-appservice-2024-11-01)、[構成のPATCH](https://learn.microsoft.com/rest/api/appservice/web-apps/update?view=rest-appservice-2024-11-01)、[起動](https://learn.microsoft.com/rest/api/appservice/web-apps/start?view=rest-appservice-2024-11-01)、[停止](https://learn.microsoft.com/rest/api/appservice/web-apps/stop?view=rest-appservice-2024-11-01)、[各RBAC操作](https://learn.microsoft.com/azure/role-based-access-control/permissions/web-and-mobile#microsoftweb)。

## Functions / Flex Consumption試験

2026-11-06、ユーザーが次の対象にFunctionsを指定し、LinuxのFlex Consumptionを選択した。同日22:16 JST、専用アプリでSandboxのFunctions一覧を独立取得し、Complete=true・0件を確認。App Serviceの削除確認と合わせた非秘密の結果をTEMPのUTF-8テキストへ保存した。実ID・出力ファイル名はこの文書へ保存しない。

### 作成と権限の区別

`scripts/New-SandboxFunctionApp.ps1`はユーザー実行専用。既定のPlanはローカルで計画を表示・保存する。Createはユーザーの明示的なサインインで、Sandboxの試験用RG（なければ作成）、Linux FC1プラン、専用StorageV2/Standard_LRS、非公開の配置コンテナー、空のFunction Appを作成する。LocationとResourceGroupNameを指定できる。アプリ・プラン・Storageのいずれかが既にあれば、上書きも自動再開もしない。

- Node.js 22、2048 MB、最大インスタンス数40、always-ready 0。最大値は割り当て済み台数ではない。関数コード、トリガー、Application Insightsは作成しない。計画時点では、選択リージョンの提供状況・実クォータ・実作成可否は未確認。登録済みプロバイダーの確認だけで容量を保証しない。
- Function AppはHTTPSのみ・公開ネットワークアクセス無効。Storageは公開ネットワーク経由の認証付き接続を使い、匿名Blobアクセスと共有キー認証を無効にする。VNet/Private Endpointは作らない。Storageの鍵や接続文字列は取得しない。
- Function App自身のシステム割当マネージドIDへ、試験用Storage 1件をScopeにしたStorage Blob Data OwnerとStorage Table Data Contributorをユーザーの作成操作で割り当てる。前者はホスト/配置用Blobの読み書き・削除・アクセス制御、後者はホスト診断用Table/エンティティの読み書き・削除を可能にする。自動失効なし。これは運用専用アプリへの変更権限付与ではなく、Function Appの実行用権限。割当IDと実際のマネージドIDをレポートへ記録する。
- 共通の運用専用アプリには、この作成スクリプトで追加権限を与えない。後続の操作試験用の許可は、作成結果を確認し、必要な操作とFunction Appの個別Scopeを説明してからユーザーが別途付与する。
- Microsoft.WebとMicrosoft.Storageの登録状態を作成前に確認する。未登録時の自動登録、SKU/リージョンの自動変更、失敗した書き込みの再試行、ロールの自動拡大・解除、リソースの自動削除はしない。途中失敗では、作成済みリソースと権限割当が残る場合がある。
- OutputPathはリポジトリ外の新規txt。計画、プロバイダー確認、作成段階、権限の付与先/Scope、結果だけを1行1JSONでUTF-8保存する。ARM生レスポンス・設定一覧・例外本文は記録しない。既存レポートの上書きは禁止。ARMエラーは共通の要約で残す。

試験手順は、ユーザーによる作成→専用アプリで一覧/検索/種類・プラン・ランタイム等の取得→ユーザーによる個別変更権限の付与→停止/起動・Functions構成の変更/復元→ユーザーによる権限解除→読み取り継続確認→ユーザーによるFunction App・プラン・専用Storageの削除と不存在確認。空のアプリの管理操作試験であり、HTTP関数・トリガー・ホストの正常動作を検証したとは扱わない。

### 検証状況

- オフライン200項目に成功。計画だけの場合の非接続、対象の非上書き、認証先の照合、非対応Flex設定の不使用、クォータ失敗時のStorage未作成、Storageの保護設定、他サービス/別ID/意図しないalways-readyの拒否、運用アプリとホストIDの分離、個別Storageへの2ロール限定、失敗時の非再試行、レポートの非上書き・秘密値の非出力を確認。実Azureへは作成・付与していない。
- 実際の接続設定を使ったローカルPlan表示と、生成したTEMPレポートの読み直しに成功。作成前計画の表示であり、Azureの事前検証ではない。最後にTest-Repository.ps1全体を1回実行し、全1176項目に成功した。スキルの形式と配布元/予定配布先の参照もこの検証に含む。
- Pythonについては、PATH先頭とmiseだけの確認では登録済み本体を見落としていた。ユーザーの指摘後に登録済みPython 3.11のパスを確認し、そのフルパスと-B -X utf8でskill-creatorのquick_validate.pyを実行。通常の隔離環境で3スキルすべてSkill is valid!を確認した。Pythonや依存パッケージの追加、環境設定変更はしていない。
- ユーザー提供結果（同日22:34～22:36 JST）: Createの保存ログにSucceededと終了コード0を確認。Japan EastにRG、Linux FC1プラン、専用Storageと非公開コンテナー、Function Appを作成し、Function App自身のマネージドIDに対してStorage 1件のBlob Data Owner・Table Data Contributorを割り当てた。運用専用アプリへの変更権限は追加していない。
- 独立した実取得（同日22:38 JST）: 専用アプリでFunction AppとプランをGETし、Functions/Linux・Running・Japan East・FC1・Node.js 22・2048 MB・最大40・always-ready 0・HTTPSのみ・公開アクセス無効・システム割当IDを確認。関数一覧は空で、プラン内アプリ数は1。Functions一覧はComplete=true・1件、RG/キーワード一致1件・不一致0件を確認し、選択した非秘密項目だけをTEMPへ保存した。StorageやそのRBAC割当自体の独立取得はしていない。
- 操作試験用にSet-SandboxFunctionsAccess.ps1とInvoke-SandboxFunctionsTest.ps1を追加。前者はユーザー実行のPlan/Grant/Revokeで、運用専用アプリに個別Function Appだけのstart/action・stop/action・sites/writeを付与する。DataActionsなし、プラン/Storage/ロール管理/秘密取得/削除の操作は追加しない。sites/writeは上限設定だけに限定されず、そのアプリの他構成も更新できる。Revokeは完全な割当ID・Scope・主体・ロールを照合して1件だけ解除し、既存Readerとホスト用Storage権限は残す。自動失効なし。
- 後者は既定で計画保存のみ。-Executeで専用アプリから停止→起動、maximumInstanceCount 40→41→40を行い、各段階をGET検証する。既存のruntime/deployment/scaleAndConcurrency/siteUpdateStrategyを保持したPATCHを使用し、上限以外のfunctionAppConfigをキー順に依存せず比較する。関数0件、期待するホストID、公開アクセス無効、Node.js 22・2048 MB・always-ready 0、単独のFC1プランが前提。Storageや権限への要求は出さず、失敗時に変更の再試行や自動復元はしない。ARM上の管理操作だけの試験であり、コードやホストの正常動作は未検証と記録する。
- オフライン54項目: Grant/Revokeの個別Scope、対象主体、既存ロールの厳密照合、FC1/Linuxの確認、Web App/Logic Apps Standard/別サブスクリプション/スロットの拒否、指定割当だけの解除、失敗時の非再試行を確認。
- オフライン151項目: 4操作の順序とGET検証、全functionAppConfigの保持と比較、キー順序の違い、他の関数がある場合の変更前停止、認証先・ホストID・Storage接続先の照合、保護設定の変化検出、復元失敗時の停止・非成功扱い、秘密値や関数情報の非記録、レポートの非上書きを確認。実Azureの結果とは区別する。
- 操作ヘルパー追加後、最後にTest-Repository.ps1全体を1回実行し、全1397項目に成功。実接続設定を使った権限Planの表示・TEMP保存・読み直しも成功した。成功済みオフライン結果の要約をTEMPのテキストに保存し、Azureでの変更試験とは区別している。
- ユーザー提供のGrantログから、運用専用アプリのサービスプリンシパルに今回のFunction AppだけをScopeとするstart/action・stop/action・sites/writeの割当成功を確認。DataActionsは空で、従来のReader割当は別に残る。新規ロール定義ID・割当IDはユーザーのTEMPログで追跡し、リポジトリには保存しない。
- 独立した実操作（同日22:53 JST）: 専用アプリの証明書認証でRunning→Stopped→Running、maximumInstanceCount 40→41→40を実行し、各段階をGETで確認。最終状態はRunning・最大40・always-ready 0。上限以外のfunctionAppConfig、HTTPSのみ、公開アクセス無効、ホストID、プランとの関連を維持。プランの比較対象（所在地・SKU/tier・Linux・アプリ数1・perSiteScaling・zoneRedundant）は変化なし。関数一覧は前後とも0件。秘密値・設定一覧・ARM生レスポンスは記録していない。
- 実操作の12イベントをTEMPのUTF-8テキストに保存し、4段階のVerifiedとFinal/Succeededを読み直して確認した。終了コード0。関数コードの配置・呼び出し・ホスト正常性・Storageデータ操作を検証した結果ではない。
- ユーザー提供のRevokeログ（同日22:56 JSTに保存開始）で、今回の運用専用アプリへの個別割当削除とAssignmentAbsent=trueを確認。既存Readerとロール定義は残す手順であり、Function App自身のStorage権限の解除は含まない。独立したRBAC照会や、解除後の拒否確認のための変更要求は実施していない。
- 独立した実取得（同日23:01 JST）: 専用アプリの証明書認証でFunction AppとプランをGETできた。アプリはRunning・Node.js 22・2048 MB・最大40・always-ready 0・HTTPSのみ・公開アクセス無効・同じホストIDとプランへの関連を維持。プランはJapan East・Linux・FC1・アプリ数1・Ready/Succeeded。選択した非秘密項目と証拠の区別をTEMPのUTF-8テキストに保存した。Storage自体は照会していない。
- 後片付け（同日23:06 JST）: ユーザーからFunction App・プラン・専用Storageの削除報告を受領。専用アプリのGETでFunction Appとプランの両方404、Functions一覧の対象RG検索でComplete=true・0件を独立確認した。Storageの不存在は現在の読み取り権限の範囲外のため独立確認しておらず、ユーザー報告として記録する。追加権限・変更操作は行わず、この証拠の区分をTEMPのUTF-8テキストに保存した。
- 新しいヘルパーは試験専用としてソースに保存し、Install-Skillsの配布対象には追加していない。FunctionsのSKILL.mdに追加したFlex固有の注意点も、配布済みコピーへは未反映。

公式根拠: [Flexのリソース作成](https://learn.microsoft.com/azure/azure-functions/functions-infrastructure-as-code?pivots=flex-consumption-plan)、[Flex設定の違い](https://learn.microsoft.com/azure/azure-functions/functions-app-settings#flex-consumption-plan-deprecations)、[マネージドIDによるホスト接続](https://learn.microsoft.com/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host)、[Storage組み込みロール](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage)、[課金](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#billing)。
管理操作の根拠: [Functionsの管理操作](https://learn.microsoft.com/azure/azure-functions/monitor-functions-reference#activity-log)、[構成のPATCH](https://learn.microsoft.com/rest/api/appservice/web-apps/update?view=rest-appservice-2024-11-01)、[上限の変更](https://learn.microsoft.com/azure/azure-functions/event-driven-scaling#limit-scale-out)、[既存siteUpdateStrategyの保持対象と対応API](https://learn.microsoft.com/azure/azure-functions/flex-consumption-site-updates#configure-your-update-strategy)。

## 実地試験を踏まえたSKILLの見直し

2026-11-06に3つのSKILLと共通手順を見直した。試験用の固定値は共通化せず、次の手順を反映した。

- 共通: 各操作後のGETと復元確認、ARM上の状態と実際の動作検証の区別、プロバイダー登録待ち・モジュール警告への対応、権限解除と後片付けの証拠の区分、UTF-8テキストへの結果保存。
- App Service: 手動作成されたプランのOS・所在地の実取得、共有プランと同居アプリの比較項目、Windowsの試験結果をLinuxへ広げないこと。
- Functions: Flexの入れ子の設定・更新方式・プランへの関連を維持し、変更後と復元後に照合すること。ホスティング方式やトリガーが異なる場合の検証範囲の区別。
- Logic Apps: Consumptionの有効化・無効化と定義更新の分離、定義等の非出力比較、状態確認とトリガーの実行試験の分離。

見直し後、quick_validate.pyで3スキルすべてSkill is valid!を確認した。配布予定15ファイルのソースと参照先を確認し、Install-Skills.ps1の-WhatIfも成功した。今回は手順書のみの変更のため、全スクリプトテストやAzure操作は再実行していない。配布済みコピーは更新せず、9ファイルの相違と6ファイルの不足を記録した。

## 第1段階: 認証分離・一覧と検索の効率化

2026-11-07に認証処理をAuthentication.ps1へ分離した。Common.ps1経由の既存関数名・呼び出し方を保ち、接続先照合と証明書認証を維持している。共通認証手順を3スキルから参照する方式へ整理し、配布対象は各8件、合計24ファイルとなった。配布済みコピーは更新していない。

- オフライン: 最後にTest-Repository.ps1を1回実行し、1584項目成功。従来の一覧117、要約・保存結果142、実ファイル保存17を含む。模擬1000件で表示20件以内、サービス混在・RG境界・ページ途中の失敗・秘密値を模した追加項目の非出力・従来形式互換・古い保存結果の明示を確認した。TEMPの保存試験ではUTF-8、全一致結果の保持、上書き拒否、取得失敗時の未保存、再表示での非接続を確認し、専用試験ディレクトリを削除した。
- 形式・配布: quick_validate.pyで3スキルが成功。新しいAuthentication.ps1、Get-InventoryReport.ps1、authentication.mdを含む24ファイルのソース・配布予定参照を検証し、-WhatIfは書き込みなしで成功した。
- Sandboxの独立実取得（00:10 JST）: 専用アプリでService Allの取得がComplete=true・0件。保存結果を再表示してSource=SavedReport・同じ取得時点・0件を確認。従来形式のApp Service一覧も0件。00:12には残存する試験用RGを管理メタデータから選び、RG単位のAllとキーワード検索でComplete=true・0件を確認した。実リソースを作成して検証してはいない。
- 本番の独立実取得（00:15 JST）: 実装中のユーザーによる追加許可に基づいて実施。Service Allで28件（App Service 7、Functions 5、Logic Apps 16）を取得し、Summaryは20件・全件は保存ファイルに保持。Get-InventoryReport.ps1で過去の同じ取得結果から1件表示し、省略を明示。RG内のキーワード検索2件と対象IDの一致、従来形式のApp Service一覧7件も確認した。
- 認証・権限: すべて既存の専用アプリの証明書認証で実行した。ユーザーは本実装中の対話サインイン利用も許可したが、実際には使用していない。Azure設定・リソース・権限の変更は行っていない。
- 証拠: 全オフライン検証、Sandboxの全件・RG検索、本番の全件・RG検索と確認結果をそれぞれTEMPの新規UTF-8テキストへ保存した。実環境ID・RG名・整形済みの個別結果はリポジトリへ転記しない。本番での詳細構成取得・変更・配置や第2段階以降を検証済みとは扱わない。


## 第2段階: 詳細取得・定型変更（2026-11-07）

実装範囲と使用例は [詳細取得と定型変更](service-operations.md) に記録する。第1段階の既存変更を維持して追加実装した。実環境ID・作成結果・権限割当IDはTEMPの結果ファイルに保持し、ソースへ固定しない。

- 模擬検証: 詳細取得と定型変更194項目、App Service権限54項目、Functions権限60項目、Logic Apps権限41項目に成功。Logic Apps権限の既存テストを単独実行できるファイルへ移し、別名の試験RG/ワークフローでも個別Scopeを検証した。
- 実取得: 専用アプリでSandboxのLinux Web AppとFlex、許可された本番の3サービス各1件を取得。セクション選択と許可項目のみのUTF-8保存が成功した。Logic Apps Standardの実リソースは今回の代表3件には含まれない。
- Web App変更: ユーザーが既存のLinux P0v4・1台のプランへ空アプリを作成し、ユーザーが起動・停止・再起動・sites/writeをそのアプリだけに付与。専用アプリで停止→起動→再起動、セッション固定false→true→false、HTTPS限定true→false→trueを実行した。公開アクセスはDisabledのまま。8ステップ中7ステップが変更後GETで一致、公開アクセスの1ステップはAlreadyDesiredで無変更。最終の取得対象メタデータとプランのSKU・台数は試験前と一致した。
- 認証例外: ユーザーは今回の試験に限り自身のサインイン権限の使用を許可したが、Codexからのユーザー認証はWAMのwindow handleエラーで失敗。権限変更前のNotStartedで停止した。WAM設定変更や認証方式の自動切替は行わず、ユーザー端末で実行してもらった。専用アプリ認証は成功している。
- Functions変更: 共通ヘルパーで停止→起動→再起動、最大インスタンス数40→41→40を実行し、5ステップともGET確認に成功。試験前と最後のfunctionAppConfig全体の比較用ハッシュとIDハッシュが一致し、取得対象メタデータ・プランも試験前に一致した。
- Web App権限解除: ユーザー端末の結果ファイルで、今回の割当IDだけを解除しAssignmentAbsent=trueになったことを確認。カスタムロール定義と既存の読み取り割当は残る。独立した専用アプリによるRBAC取得や、再変更による拒否確認はしていない。
- Logic Apps変更: 共通ヘルパーでConsumptionのEnable→Disableを実行し、2操作ともGET確認に成功。定義・パラメーターのハッシュと取得対象メタデータが試験前と一致した。HTTPトリガーは呼び出していない。最初のユーザー実行ログはサインイン開始までだったため成功扱いせず、新しいログの作成完了・権限付与結果を確認してから試験した。
- Functions・Logic Apps権限解除: ユーザー端末の各結果ファイルで今回の割当IDだけの解除とAssignmentAbsent=trueを確認した。既存の読み取り割当・カスタムロール定義は残る。独立したRBAC監査や、解除後の変更要求による拒否テストは実施していない。
- 最終検証: コード変更の最後に全オフライン検証を1回実行し、15区分の合計1835項目に成功した。3スキルの形式検証と、実際には書き込まない配布プレビューにも成功。8ヘルパー・3参照文書とSKILL.mdを各スキルへ配布する計36ファイルの参照を検証した。配置済みコピーとの比較は相違9件・未配置27件・一致0件で、自動更新はしていない。
- 後片付け前の確認（01:17 JST）: 専用アプリによる読み取りで3サービスの試験リソース各1件と、P0v4・FC1の2プランが残存していた。この時点ではユーザーによる削除実行待ちだった。Storageの取得権限は追加していない。
- 証拠はTEMPの新規UTF-8テキストへ保存した。ARM状態だけの試験で、コード・ホスト・HTTP/トリガーの正常稼働は検証していない。公開アクセスは無効のままとし、SetPublicNetworkAccessの実際の切替は模擬検証のみ。ランタイム/TLSの変更、Flexメモリ・always-readyの変更、Standard・スロット・配置・秘密設定は後続の対象とする。

### 第2段階の後片付け完了（2026-11-07）

- ユーザーの後片付け依頼に基づき、今回限りの6対象を固定した削除スクリプトをGit除外の.localへ作成した。スキル・配布対象には削除機能を追加していない。接続先、試験タグ、型・所在地、アプリとプランの関連、同居アプリ数を事前確認し、プランは空を確認してから個別に削除する。アプリ削除APIのdeleteEmptyServerFarm=falseを明示して、プラン削除を別の確認段階にした。
- 模擬検証74項目に成功。共有プラン、タグ・接続先の不一致、途中の状態変化、取得・削除失敗、削除未確認での停止と、DELETEを自動再試行しないことを確認した。最後に全オフライン検証1835項目も成功し、両方の結果をTEMPのUTF-8テキストへ保存した。
- ユーザー実行ログ（01:31 JST）: 試験Web App、P0v4プラン、試験Function App、FC1プラン、専用Storage、試験Logic Appの6件について、削除後GETで不在を確認し、最終イベントCompleted・AllSixResourcesAbsent=trueを確認した。Storage内の試験データも削除対象に含めた。
- 独立した専用アプリでの実取得（01:33 JST）: アプリ3件とプラン2件の各IDがHTTP 404。Sandboxの対象3サービス一覧もComplete=true・0件だった。Storageは既存読み取り権限に含まれないため再取得せず、ユーザー実行ログ内のGET確認を根拠にした。検証結果は別の新規UTF-8テキストへ保存した。
- RG、専用エンタープライズアプリ、証明書、カスタムロール定義、既存の読み取り割当は保持した。試験用の変更割当は先に解除済み。この後片付け時点では配置済みスキルの更新・コミット・プッシュは実施していなかった。

### 配置済みスキルの更新（2026-11-07 01:40 JST）

- ユーザーの明示的な更新依頼に基づき、このPCのユーザー共通フォルダーにあるazure-appservice・azure-functions・azure-logicappsを更新した。編集元の共通scriptsを、各スキル内のscriptsへ同梱する構成を維持した。
- 既存版は各3ファイル、合計9ファイル。新しい配布内容は各12ファイル、合計36ファイル。既存のInstall-Skills.ps1を使って読込先の外に事前配置し、配布元とのSHA-256一致を確認してから、3つの対象フォルダーだけを入れ替えた。
- 旧版はLocalAppDataのAzureOpsSkills配下へ退避し、退避前のハッシュと一致することも確認した。スキルの読込先にバックアップを置かず、重複検出を避けた。新しい配置先36ファイルすべての配布元との一致を確認し、更新結果をUTF-8テキストへ保存した。
- スクリプトのコード変更はないため、オフラインテストを再実行せず、配布物とバックアップの照合を実施した。Azure・他のスキル・認証設定は変更していない。今回の更新依頼を、今後の自動上書き許可として扱わない。

