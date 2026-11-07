# App Serviceの認証・SCM診断と配布確認

## 準備完了の読み取り確認

`Wait-AppServiceReady.ps1 -SubscriptionId <ID> -ResourceId <WEB_APP_ID> -HealthPath /healthz -ExpectedJsonStatus ok -OutputPath <NEW_ABSOLUTE_PATH.txt>` を使う。本人認証やPDF生成は含めない。CLIは管理メタデータから正確なメインホストを取得し、専用証明書接続・Running・enabledを確認した後に待機する。Azureの起動・設定変更は行わない。メインへトークン・Cookieは送らず、リダイレクトしない。

暫定値はOverallSeconds=300、RequestSeconds=10、IntervalSeconds=5（要求完了後）、ConsecutiveSuccesses=2。期待ステータスは200〜299の明示値（既定200）。期待する小さなJSONのstatus値を必要に応じて指定する。本文は4096バイトまで、値はログに残さない。ヘルスGETの副作用がないことは案件で確認する。

全体期限はHTTP待機開始からの単調時計で測る。管理API・接続の事前確認時間とは別。変更要求の受付からHTTP待機開始までの空白を案件で記録し、タイムアウト後の再確認は新しい観測区間として扱う。各要求と本文読取り、待機を残り時間へ制限し、CancellationTokenを要求・本文・待機へ適用する。期限後に応答が届いても成功にしない。キャンセル時は通信を破棄する。OSのDNS等の終了遅延は実行環境でも検証し、設定値だけで厳密なプロセス終了を保証したと説明しない。

502/503/504と要求タイムアウトのみ期限内で継続する。一時応答候補であり起動中の証明ではない。401/403/302/404・本文不一致はUnexpectedResponse、DNS/TLS等の通信失敗はTransportFailureとして停止する。全体期限はDeadlineExpired、取消はCanceled。連続成功以外は成功数をリセットする。ReadyObservedは本人ログイン・業務成功・プロセス再起動・全インスタンスの正常性を証明しない。

プラットフォームのウォームアップとHealth Checkは外部GET待機とは別。Linuxコード配布にもWEBSITES_CONTAINER_START_TIME_LIMITが適用される。診断のために起動制限・ヘルス設定を変更しない。公式: [設定一覧](https://learn.microsoft.com/azure/app-service/reference-app-settings#app-environment)、[Health Check](https://learn.microsoft.com/azure/app-service/monitor-instances-health-check)、[HttpClientの期限](https://learn.microsoft.com/dotnet/api/system.net.http.httpclient.timeout)。

## 共通比較と検証失敗後の確認

ConfigurationComparison.ps1は外部通信しない。Get-OpsConfigurationDifferenceは差分パスだけを返し、値・動的なURLキーを出さない。ResourceId/PermissionScope/serverFarmIdとuserAssignedIdentitiesのARMキーのみ形式検証して大小文字を正規化する。通常の文字列や配列は順序・型・null/空/欠落を保持する。参照先のprincipalId/clientIdの違いは拒否する。

Get-OpsAppRoleComparisonはGUIDによる対応付け、全書込みフィールド、メンバー種別を比較する。順序だけは無視し、追加・欠落・重複・無効化を検出する。originは比較用の書込み射影に含めない。未知項目は拒否する。Get-OpsPropertyReviewは既知の書込み項目と観測専用項目を明示して未知項目名を返す。Known=falseのまま更新しない。Graphへの接続・更新・権限付与は実装せず、案件の承認された実行主体を維持する。

redirectUriSettings等の自動補完を単に除外して成功にしない。元の基準、期待変更、現在観測を分けてInspectし、補完項目の意味・書込み可否を確認する。公式資料に差があれば未知項目を通さず根拠を調査する。[appRole](https://learn.microsoft.com/graph/api/resources/approle)、[REST webApplication](https://learn.microsoft.com/graph/api/resources/webapplication)、[Bicep applications](https://learn.microsoft.com/graph/templates/bicep/reference/applications)。

共通定型操作はExecuteと排他的な-Verifyを使える。同じSubscriptionId/ResourceId/Operation/Valueと元のReviewedPlanPath、新規OutputPathを指定する。計画期限切れでもGETによる確認だけはできる。元のBeforeから意図した変更だけを適用して比較し、書込みやローカル対象ファイル更新を行わない。失敗時はDifferentPropertiesを記録する。手動で計画を書き換えて不一致を消さない。

## 起動診断の証拠と権限

要求送信・受付、管理状態、配布状態、プラットフォーム起動/停止、Java待受/終了、ヘルス開始/終了をUTCとインスタンス識別情報で対応付ける。ファイル数・時刻の範囲・抽出行数・欠落区間・未取得を記録する。OOM等の検出なしは十分なログや障害なしの証明ではない。Activity Logだけで全再起動やアプリ内部を把握しない。LinuxのSCMプロセス情報を本体Javaの情報にしない。usagesの0/-1、空メトリック、取得失敗を余裕や無制限の根拠にしない。

既存権限で取得不可なら停止して、対象・UTC範囲・リポジトリ外の新規保存先を固定したユーザー用PowerShell 7コマンドを案件で準備する。既存Azと共通接続を優先し、自動昇格・別主体切替・モジュール追加はしない。Kudu Diagnostic dumpは既存ログ取得の候補。publish/actionは読取り専用権限ではない。生ログZIPはユーザー管理のローカルに保管し、チャットやGitに出さない。ログ有効化・診断設定は費用・秘密情報・再起動を伴い得る別変更として判断する。[ログ取得](https://learn.microsoft.com/azure/app-service/troubleshoot-diagnostic-logs#access-log-files)、[Kudu権限](https://learn.microsoft.com/azure/app-service/resources-kudu#rbac-permissions-required-to-access-kudu)。

テストは合成時系列・ローカルHTTPと実Azureを区別する。実Azureでは承認された操作機会に、書込み1回、段階別時刻、連続期待応答、制限維持、キャンセルと期限を確認し、本人ログインと架空業務要求を別検証する。原因確認だけの再起動を繰り返さない。

共通認証はauthentication.md、変更・権限・停止境界はchange-workflow.mdに従う。
この文書はApp Service Web App向け。Functions、スロット、別クラウドで同じ動作を保証しない。

## 読み取り診断

ソースではscripts、配布先ではSKILL.mdの隣のscriptsにあるGet-AppServiceDiagnostics.ps1を使う。
既定はAuthenticationだけ。PublishingPoliciesは基本認証ポリシー、Scmはネットワーク要約とメイン／SCMのHTTP GETを追加する。
必要な項目だけ指定し、完全な対象IDとリポジトリ外の新規絶対パス.txtを渡す。

~~~powershell
pwsh -NoProfile -File '<HELPER_PATH>\Get-AppServiceDiagnostics.ps1' -SubscriptionId '<SUBSCRIPTION_ID>' -ResourceId '<WEB_APP_RESOURCE_ID>' -Section Authentication -OutputPath '<NEW_AUTH_LOG_PATH>.txt'
pwsh -NoProfile -File '<HELPER_PATH>\Get-AppServiceDiagnostics.ps1' -SubscriptionId '<SUBSCRIPTION_ID>' -ResourceId '<WEB_APP_RESOURCE_ID>' -Section Scm -OutputPath '<NEW_SCM_LOG_PATH>.txt'
~~~

複数Sectionをまとめる場合は、案件内のPowerShellラッパーから配列で渡す。
pwsh -Fileの引数にカンマ区切りを渡せば配列になるとは仮定しない。
作成・更新・起動・配布・権限付与は行わず、Azure Monitorのメトリックも自動取得しない。

診断は段階別のUTF-8 JSON Linesを保存する。任意項目の取得に失敗しても、接続主体・対象を照合できる独立した項目は継続する。
失敗した要求は再送せず、末尾のCompletedでComplete=falseを記録してエラー終了する。
対象GETの失敗、ID不一致、別サービス、接続主体不一致、ホスト不一致では依存する診断を止める。
Retrieved=trueはその応答を観測できた意味であり、アプリが正常、安全、配布可能である証明ではない。
過去ログのSource=Liveは取得時点の出所。現在値の確認には再取得が必要。

## authsettingsV2の検証

プロバイダー名の公式スキーマと、実レスポンスの値を分ける。
facebook、gitHub、google、twitter、legacyMicrosoftAccount、appleを扱い、azureActiveDirectory、azureStaticWebApps、customOpenIdConnectProvidersも見落とさない。
カスタムOIDCは名前から設定へのマップであり、全体に一つのenabledがある構造ではない。

Get-OpsAppServiceProviderSummaryはenabledのEnabled／Disabled／Missing／Null／Invalidと登録情報の有無を別に返す。
clientId、appId、consumerKey、秘密参照設定は存在フラグだけを返し、値や未知のプロバイダー名・カスタム別名を出さない。
未知項目は件数として診断できるが、自動更新へ進む根拠にはしない。
登録IDがないのにenabled=trueが返された案件の観測を、全環境の既定値・ログイン可能性として一般化しない。

使用しないことを明示したプロバイダーは、変更計画の対象としてenabled=falseを明示できる。
その前にGETし、既存の登録ID、consumerKey、秘密参照設定、未知の登録項目を持つプロバイダーは勝手に無効化・置換しない。
Assert-OpsAppServiceUnusedProviderChangeはpropertiesの変更前後と明示したUnusedProviderを受け、未登録の6種のenabled変更だけを許容する。
他プロバイダー、カスタムOIDC、login、globalValidation等の保持を全体比較し、入力を変更しない。PUT自体は実行しない。

このガードは認証設定全体の適合判定ではない。テナント・issuer・audience・許可クライアント／本人・認証必須・未認証応答・除外パスは、案件の承認済み要件と別に照合する。
更新要求は公式の書込可能な項目から作り、GET生レスポンス全体をそのままPUTしない。送信直前のGETと更新後GETで変更対象と維持対象を確認する。

## SCMの403を診断する

stateは現在の実行状態、enabled=falseはアプリをオフラインにする設定、scmSiteAlsoStoppedはアプリ停止時にSCMも停止させる設定。
三つを別々に確認し、scmSiteAlsoStopped=falseだけでSCMへの到達を保証しない。App Serviceのenabled変更を、Logic Apps専用のEnable/Disableへ混ぜない。

1. 失敗段階と対象がARMかメインかSCMかを確認する。
2. 専用アプリでstate・enabled・SCM停止設定・公開アクセス・実ホスト名を取得する。
3. ネットワーク設定のSCM継承と既定動作を調べ、メインとSCMのGET応答を観測する。
4. 停止ページの既知マーカー、IP Forbidden、IP拒否ヘッダーの存在、構造化された認証／権限エラーを分ける。
5. 複数の根拠が矛盾すればConflictingEvidence、根拠がなければUnknownとして追加の許可済み調査へ進む。

Get-OpsAppServiceHttpSummaryはHTTPステータスと安全な分類・フラグだけを返す。HTML、エラー本文、ヘッダー値は保存しない。
HTTPプローブは確認済みWeb Appのメタデータからホストを決め、HTTPS・GET・リダイレクト禁止・30秒上限とする。
管理トークンはSecureStringのままメモリで使用し、SCMの正確なホストだけへ送る。メインには送らない。

403だけでRBAC不足と断定しない。停止を示す403が有効化で解消し、同じ管理アプリ・権限で配布できた案件はあるが、すべての403が停止原因ではない。
権限追加、管理者接続、IP制限や認証の解除で切り抜けない。

## IPv4制限の照合

単一出口IPv4 /32を使う案件では、Assert-OpsAppServiceIpv4Restrictionへ承認済みのAllowedCidrとconfig/webのpropertiesを渡せる。
メインと有効なSCMルールのdefault Deny、唯一の/32 Allow、優先度、SCM継承、想定外の追加ルールを検証する。IP自体は要約へ出さない。
複数ルール、Private Endpoint、サービスエンドポイント等へ適用する汎用ガードではなく、既存構成の自動置換にも使わない。
同じグローバル出口IPを共有する端末にも一致する。物理的なこのPCだけの制限とは説明しない。IP制限と本人認証は別の制御。

## 配布と動作確認

配布コードと対象・成果物ハッシュ・ログ保存先は案件内に用意する。共通の配布実行コマンドは追加していない。
承認済みの対象について、次の段階を分ける。

1. 直前GETで認証とメイン／SCM双方のアクセス制限を要件に照合する。
2. enabledとstateを確認する。有効化が必要なら、公開到達性・既存コードやトリガーの稼働を含めて変更計画へ入れる。失敗ハンドラーから自動有効化しない。
3. Kudu OneDeployのPOST /api/publish?type=zip&async=true&restart=falseへ、確認済みZIPを一度だけ送る。zipdeployのisAsync=trueと混同しない。
4. 202は受付にすぎない。LocationはResolve-OpsAppServiceDeploymentLocationで同一SCMホスト・HTTPS・許可パスを確認し、上限付きGETで配布完了を確認する。Get-OpsAppServiceDeploymentSummaryでは4が成功、3が失敗。タイムアウト・不明状態でZIPを再送しない。
5. 配布成功後、承認済みの別操作で必要な再起動を行う。restart=falseは、その配布要求で再起動を許可しない指定であり、あらゆる原因の再起動が起きない保証ではない。
6. 管理状態とHTTP結果を分ける。案件で定めたヘルスURL、未認証要求、トークンなしのX-MS-CLIENT-PRINCIPAL偽装要求を確認し、その後に本人サインインを伴う業務要求を検証する。

ヘルス200と拒否401だけで、認証済みの業務処理、全認可経路、メモリ上限、タイムアウト・復旧、運用準備まで成功としない。
PDF等のPOST、本人サインイン、負荷試験は読み取り診断に含めず、影響を確認した案件スクリプトで実行する。

## 追加権限と引き渡し

初期のroles/services-reader.jsonは広げない。必要な読み取りだけを、ユーザーが専用アプリのサービスプリンシパルへ付与・解除する。

| 対象Scope | 追加Actionと用途 |
| --- | --- |
| 個別Web App | Microsoft.Web/sites/basicPublishingCredentialsPolicies/read：FTP/SCM基本認証ポリシーのallow確認 |
| 個別Web App | Microsoft.Insights/metricDefinitions/read、Microsoft.Insights/metrics/read：対象アプリのメトリック定義・値 |
| 個別App Serviceプラン | メトリック定義・値の読み取り2操作だけ |

基本認証ポリシーのallow読み取りは公開資格情報の取得ではない。config/list/action、publishxml/read、アプリ設定値や接続文字列の取得を追加しない。
ScmのHTTP診断にはKuduへの既存のpublish/action権限が必要になり得る。GETだから初期Readerで使えるとは説明せず、403を根拠に自動追加もしない。
Get-OpsAppServiceDiagnosticPermissionPlanは必要Actionと個別Scopeの案だけを返す。IncludeMetricsとPlanResourceIdは明示指定し、実際の関連はGETで照合する。RG割当・ロール変更・メトリック取得はしない。

ユーザー操作が必要なら、先に案件内のスクリプトとリポジトリ外の新規ログパスを確定し、短いpwsh -NoProfile -Fileコマンドを示す。
ユーザーが終わったと伝えたら、そのログを読み、対象・取得時刻・実行主体・成功／部分完了／失敗を照合して続ける。発言だけで成功と見なしたり、同じ操作を再実行してもらったりしない。
測定では実行区間とメトリック定義・粒度を記録する。データなしは0とせず、短いメモリピークを粗い集計だけで捕捉できたと断定しない。

## 根拠と検証範囲

- [authsettingsV2を含む2024-11-01スキーマ](https://learn.microsoft.com/azure/templates/microsoft.web/2024-11-01/sites/config#identityproviders)
- [enabled・state・SCM停止設定](https://learn.microsoft.com/rest/api/appservice/web-apps/update?view=rest-appservice-2024-11-01)
- [SCM基本認証ポリシーのGET](https://learn.microsoft.com/rest/api/appservice/web-apps/get-scm-allowed?view=rest-appservice-2024-11-01)
- [WebのRBAC操作](https://learn.microsoft.com/azure/role-based-access-control/permissions/web-and-mobile#microsoftweb)
- [監視のRBAC操作](https://learn.microsoft.com/azure/role-based-access-control/permissions/monitor#microsoftinsights)
- [メインとSCMのアクセス制限](https://learn.microsoft.com/azure/app-service/app-service-ip-restrictions)
- [Kudu publish APIとrestart](https://learn.microsoft.com/azure/app-service/deploy-zip#kudu-publish-api-reference)
- [Kuduアクセスの権限](https://learn.microsoft.com/azure/app-service/resources-kudu#rbac-permissions-required-to-access-kudu)
- [OneDeploy asyncとzipdeploy isAsyncの公開実装](https://github.com/projectkudu/kudu/blob/master/Kudu.Services/Deployment/PushDeploymentController.cs)
- [公開実装の配布状態enum](https://github.com/projectkudu/kudu/blob/master/Kudu.Contracts/Deployment/DeployStatus.cs)

2026-11-07に公式資料と別案件の実施記録を照合して抽出した手順。公開Kuduコードと対象Azureの稼働版が同一であることは未確認。
追加したテストは合成データと模擬通信によるオフライン境界確認。別案件の観測、ユーザー提供ログ、独立したAzure実取得を区別し、このリポジトリでAzure再現試験済みとは扱わない。
