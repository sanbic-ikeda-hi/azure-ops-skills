# Azure Ops Skills

App Service・Functions・Logic Apps を扱う共通スキルと、
専用アプリによる認証・取得を支える PowerShell スクリプトの配布元。

## コマンド

リポジトリ直下で実行する。

| 用途 | コマンド |
|---|---|
| オフライン検証 | `pwsh -NoProfile -File .\scripts\Test-Repository.ps1` |
| 配布予定の確認 | `pwsh -NoProfile -File .\scripts\Install-Skills.ps1 -WhatIf` |
| ユーザーによる配布 | `pwsh -NoProfile -File .\scripts\Install-Skills.ps1` |

- Azure 初期設定は `docs/setup.md`、別 PC 登録は `docs/recovery.md` に従う。
- 初期設定・PC 登録・実際の配布はユーザーが実行する。

## 守ること

- 共通スキルの編集元は `skills/` とし、配布済みコピーとの違いを明示する。
- リポジトリの変更だけで配布済みスキルも更新されたと扱わない。
- 配布先の既存スキルを自動で上書きしない。
- Microsoft 製スキルの全文を複製せず、必要な場面で参照する。
- Azure 操作は専用アプリの証明書認証を維持し、管理者接続へ自動で切り替えない。
- 接続先のテナント・サブスクリプション・アプリ ID・認証種別の照合を維持する。
- 読み取りロールは明示的な管理メタデータ取得に限定し、秘密取得やワイルドカードを追加しない。
- 変更権限は承認された個別リソースに限定し、付与・解除はユーザーに案内する。
- 新規リソースの最初の作成は、対象・費用・影響を示してユーザーが実行する。
- スキルによる削除・ロック解除・自動権限付与を追加しない。
- 実環境 ID・接続プロファイル・証明書・Azure の生レスポンスを Git に入れない。
- Azure 操作の詳細な手順と制約は `docs/change-workflow.md` と `docs/security.md` に従う。

## 完了の条件

- スクリプトを変更した場合は、最後にオフライン検証を実行して成功を確認する。
- スキルとヘルパーの参照先が、配布元・配布先の両方で成立することを確認する。
- オフライン検証・ユーザー提供結果・独立した Azure 実取得を区別して報告する。
- GitHub への登録前に対象ファイルを確認し、除外設定だけで秘密の不存在を保証しない。

## スキル

- App Service の調査・操作方針は `skills/azure-appservice/SKILL.md` を参照する。
- Functions の調査・操作方針は `skills/azure-functions/SKILL.md` を参照する。
- Logic Apps の調査・操作方針は `skills/azure-logicapps/SKILL.md` を参照する。
