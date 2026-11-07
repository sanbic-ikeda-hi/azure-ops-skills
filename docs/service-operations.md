# 詳細取得と定型変更（第2段階）

検証失敗後は変更を再送せず、同じ対象・操作・値・元のReviewedPlanPathで `Invoke-ServiceOperation.ps1 -Verify` を使う。新規OutputPathを指定し、Executeとは併用しない。新しい計画のExpectedAfterを使ったGET限定照合で、期限切れ計画も読取りには使える。旧形式でExpectedAfterのない計画は手動Inspectへ進み、再送しない。変更実行では新形式の計画を作り直してレビューする。要求試行・受付・管理観測はEventsのUTC時刻、設定不一致はDifferentPropertiesを確認する。Verifyはアプリ正常性・本人ログイン・実プロセス再起動を保証しない。

認証・Windows実行ユーザーは `authentication.md`、対象選択・承認・権限管理は `change-workflow.md` に従う。通常の操作は専用アプリの証明書認証を使う。ユーザー認証への自動切替はない。

## 必要な項目だけ取得する

`Get-ServiceDetails.ps1` は完全な対象IDを1〜20件指定する。基本表示は `Overview` のみ。複数項目は同じ接続で取得し、同じアプリの構成GET・同じプランのGETを重複させない。

| Section | 内容・境界 |
|---|---|
| Overview | 状態、enabled・scmSiteAlsoStopped、所在地、プラン関連、HTTPS・公開アクセス。欠落はnullとして扱い、stateから補完しない |
| Runtime | コードランタイム、Flexのruntime・最大数・メモリ・always-ready要約。従来型Functionsのworker設定を知るためのアプリ設定取得はしない |
| Network | HTTPS、公開アクセス、TLS、FTP、VNet関連、IP制限の件数・既定動作。IPルール本文・ヘッダーは出さない |
| Identity | ID種別、principal/tenant ID、ユーザー割当IDの関連。関連先は追跡しない |
| Plan | 所在地、SKU、台数、OS、同居アプリ数。別サブスクリプションの関連先は拒否する |
| Structure | Consumptionの最上位トリガー・アクション名と型。入力、式、接続先やパラメーター値は出さない。Standardは未対応と表示 |

```powershell
pwsh -NoProfile -File <helper-dir>/Get-ServiceDetails.ps1 `
  -SubscriptionId <subscription-id> -ResourceId <resource-id> `
  -Section Overview,Runtime,Plan -OutputPath <new-absolute-path.txt>
```

`-Limit` はコレクション項目の表示上限（既定20）。件数と `DisplayTruncated` を併記する。`-OutputPath` はリポジトリ外の新規UTF-8 txt。保存するものも許可項目だけで、ARM生レスポンスではない。取得失敗時は成功済みの部分結果を完全な結果として返さない。

同居アプリの名前が必要なら、既存の一覧要約・保存結果の `PlanResourceId` で絞る。最初から全アプリの構成を取得しない。詳細ファイルの追加表示は保存済みJSONの必要なセクションだけを読む。ファイルの日時を示し、現在値として扱わない。

## 定型変更

`Invoke-ServiceOperation.ps1` は既定でGETによる計画作成だけを行う。ソースではリポジトリのscripts、配布後はSKILL.mdの隣のscriptsを使う。この文書の検証状況を確認し、個別設定やホスティング方式をすべて実証済みと扱わない。

| Operation | 対象 | Value | 必要な追加Action |
|---|---|---|---|
| Start / Stop / Restart | App Service・Functions | 指定しない | `Microsoft.Web/sites/start/action` 等の該当1操作 |
| Enable / Disable | Logic Apps Consumption | 指定しない | `Microsoft.Logic/workflows/enable/action` または `disable/action` |
| SetClientAffinity | App Service | `true` / `false` | `Microsoft.Web/sites/write` |
| SetHttpsOnly | App Service・Functions | `true` / `false` | `Microsoft.Web/sites/write` |
| SetPublicNetworkAccess | App Service・Functions | `Enabled` / `Disabled` | `Microsoft.Web/sites/write` |
| SetFlexMaximumInstanceCount | Functions Flex | `1`〜`1000` | `Microsoft.Web/sites/write` |

対象は最上位の個別アプリだけ。共有プラン、スロット、Logic Apps Standardの変更は拒否する。ランタイム・TLSの変更、Flexメモリ・always-ready変更、ID変更はまだ実装していない。アプリ設定・接続文字列・コード配置は後続段階で扱う。

1. 対象の完全ID、操作、目的、停止・接続への影響を説明する。起動・有効化はトリガーの再開や外部処理につながり得るため、先に対象の構造と接続を確認する。公開アクセスを有効にする場合は外部到達性、HTTPS限定を外す場合は通信保護の変更を明示する。最大数の変更は処理能力・下流負荷・費用へ影響し得る。
2. 現在値を取得し、計画を新規ファイルへ保存する。差分・必要Action・個別Scopeを提示する。
3. 必要時だけユーザーへ権限付与を案内する。付与先は専用エンタープライズアプリのサービスプリンシパル。`sites/write` は設定1項目だけに限定された権限ではない。初回作成や権限管理を通常の操作スクリプトに含めない。
4. 承認済みの同じ対象・操作・値を指定し、`-Execute -ReviewedPlanPath` で実行する。計画の有効期間は1時間。現在値、接続先、アプリID、操作内容が異なれば変更前に止まる。ファイルを書き換えて差分を回避しない。
5. APIの直前にも再取得し、1回だけ変更を送信する。GET確認は最大12回（間隔5秒）。権限エラーや取得失敗は再試行せず停止。復元が必要なら逆の変更として新しく計画し、明示的に実行する。

```powershell
# 計画を確認する。ここでは変更しない。
pwsh -NoProfile -File <helper-dir>/Invoke-ServiceOperation.ps1 `
  -SubscriptionId <subscription-id> -ResourceId <resource-id> `
  -Operation SetClientAffinity -Value true -OutputPath <new-plan.txt>

# 対象・差分の承認後、同じ対象・操作・値を指定する。
pwsh -NoProfile -File <helper-dir>/Invoke-ServiceOperation.ps1 `
  -SubscriptionId <subscription-id> -ResourceId <resource-id> `
  -Operation SetClientAffinity -Value true -Execute `
  -ReviewedPlanPath <absolute-plan.txt> -OutputPath <new-result.txt>
```

通常のプロパティは変更する項目だけをPATCHする。Flexの最大数は現在の `functionAppConfig` 全体をメモリ内で保持し、最大数だけを変更して送る。保存するのは要約と比較用ハッシュだけ。runtime・deployment・siteUpdateStrategy・他のscale設定を失わないことを変更後にも確認する。

実行ファイルには変更送信前の段階も保存する。`MutationSubmitted` は送信を試みたことを示し、成功を意味しない。`Succeeded` と `Stage` を確認する。現在値が既に目的の値なら `AlreadyDesired` とし、変更APIを呼ばない。Restartは要求受付とARM上のRunningだけを確認し、実プロセスの再起動やアプリ正常性を検証済みと表示しない。

直前GETは他の管理者との排他制御ではない。同時変更がある環境では作業を調整する。異常時に変更を繰り返したり自動復旧したりせず、保存された段階と新しい読み取り結果で判断する。

## 仕様の根拠

- [Web Apps Update（PATCH）](https://learn.microsoft.com/rest/api/appservice/web-apps/update?view=rest-appservice-2024-11-01)
- [Web Apps Get Configuration](https://learn.microsoft.com/rest/api/appservice/web-apps/get-configuration?view=rest-appservice-2024-11-01)
- [Web Apps Restart](https://learn.microsoft.com/rest/api/appservice/web-apps/restart?view=rest-appservice-2024-11-01)
- [Logic Workflows Enable](https://learn.microsoft.com/rest/api/logic/workflows/enable?view=rest-logic-2019-05-01)
- [Flexの最大数・スケール制限](https://learn.microsoft.com/azure/azure-functions/event-driven-scaling#limit-scale-out)：2026-11-07確認時、最小1・最大1000。旧試験の40という初期値はサービスの下限ではない。always-readyは別管理。

## 検証状況（2026-11-07）

- 共通詳細取得・変更のオフライン194項目に成功。実証明書やAzureは使わず、結果ファイルのみTEMPで検証した。
- 新しい詳細取得で、Sandbox Web Appと本番のApp Service・Functions・Logic Apps各1件を専用アプリで実取得した。本番への変更は実施していない。
- Sandbox Linux Web AppでStop/Start/Restart、セッション固定false→true→false、HTTPS限定true→false→trueを確認。公開アクセスはDisabledのまま、プラン・取得対象のメタデータは試験前へ一致した。SetPublicNetworkAccessはAlreadyDesiredによる無変更確認のみ。
- Sandbox Functions FlexでStop/Start/Restart、最大数40→41→40を確認。functionAppConfig全体の比較用ハッシュは試験前と最終状態で一致した。
- Sandbox Logic Apps ConsumptionでEnable→Disableを確認。定義・パラメーターのハッシュと取得対象のメタデータが試験前と一致した。HTTPトリガーは呼び出していない。
- 詳細取得・共通ライブラリ・変更エントリーポイント・参照文書を配布対象へ追加した。各12件、3スキル計36ファイル。配置済みスキルの更新は別途ユーザーが行う。公開アクセスを実際に切り替える試験、従来型Functionsの変更、Standardの実取得・変更、コード/ホストの正常稼働は今回未検証。

## App Serviceの追加診断

App Service向けのGet-AppServiceDiagnostics.ps1と、値を変更しないAppServiceDiagnostics.ps1を追加した。
認証プロバイダーの状態・既存登録保護、SCM応答分類、単一IPv4 /32の有効ルール照合、配布状態の判定を分けて再利用できる。
既定は認証メタデータだけを取得し、HTTP診断はScmを明示する。基本認証ポリシーの読み取りは秘密取得とは別の追加権限。
詳細はソースのappservice-operations.md、App Service配布先の同名参照文書を読む。他サービスにはApp Service専用ファイルを配布しない。

Invoke-ServiceOperation.ps1の失敗結果にはFailureDetailsとしてHTTPステータスと固定のCategoryHintを記録する。
SDKが例外を投げた場合も任意の本文は出さず、根拠を得られない分類はUnknownとする。
追加した診断・ガードはオフラインの模擬要求で検証する。Azureでの認証設定更新、SCM配布、HTTP業務処理の再現確認は別途必要。
