# Azure Ops Skills

App Service / Functions / Logic Apps を、専用のエンタープライズアプリで扱う個人用スキル集です。

- 読み取り: 指定サブスクリプション内の対象3サービス。初期ロールには取得に必要な管理メタデータの読み取りだけを登録します。
- 変更: 承認したリソースIDだけに、その回に必要な操作を追加。サブスクリプション・リソースグループへの変更権限は通常要求しません。
- 新規: 既存・新規どちらのリソースグループも選択可。管理者向け作成コマンドを用意し、ユーザーが実行。作成後の個別リソースだけを専用アプリに許可します。
- 削除、ロール付与、ロック解除、管理者への認証切替はスキルから実行しません。PIM は使用しません。

## 初期設定

1. [Azure の準備](docs/setup.md)に従い、管理権限のあるユーザーが PowerShell で実行します。
2. 初期設定は専用アプリ・PC用証明書・読み取り専用カスタムロールを作ります。クライアントシークレットや変更権限は作りません。
3. 接続後に読み取りを確認し、ユーザー共通のスキル配置先にインストールします。

必要な情報は TenantId、SandboxSubscriptionId、必要ならProductionSubscriptionId。アプリ名の初期値は azure-ops-skills です。
GitHub のリポジトリURLは、push・別PCでのclone時に必要です。

~~~powershell
# このリポジトリのルートで実行（Azureに接続しないローカル検証）
pwsh -NoProfile -File .\scripts\Test-Repository.ps1

# 共通スキルの配置先を確認（書き込みなし）
pwsh -NoProfile -File .\scripts\Install-Skills.ps1 -WhatIf

# 内容を確認した後、ユーザー自身が配置する
pwsh -NoProfile -File .\scripts\Install-Skills.ps1
~~~

配置先は Windows ユーザーの .agents\skills です。実行時の認証設定は LOCALAPPDATA\AzureOpsSkills\connection.json を使います。
既存の同名スキルは自動上書きしません。更新は旧版との差分確認後、当該フォルダー内のファイルだけを反映してください。
リポジトリの編集中の変更は、配置済みスキルへ自動反映しません。

## Microsoft製スキルとの連携

この3つをサービス別の入口にし、必要な場合だけ導入済みのMicrosoft製スキルを参照します。

| 入口 | 主な参照先 |
| --- | --- |
| azure-appservice | azure-diagnostics、App Service対応版のazure-reliability、azure-resource-lookup |
| azure-functions | azure-diagnostics、azure-reliability、azure-upgrade、azure-resource-lookup |
| azure-logicapps | azure-resource-lookup、Standardの基盤に適用できるazure-diagnosticsの手順、Logic Apps向けMicrosoft Learn |

依頼時は`$azure-appservice`、`$azure-functions`、`$azure-logicapps`のいずれかを入口にできます。Microsoft製スキルを単独で呼び出した場合に、本スキルの連携指示が自動適用されるとは扱いません。
Microsoft製は調査項目・評価方法・コマンド案を補います。実行時の認証、対象IDの確認、個別リソースへの権限付与・解除、秘密情報の扱いは本スキルの運用方針に従います。
これは指示による連携であり、他スキルのコマンドを自動的に安全な接続で包む仕組みではありません。実際の操作権限はAzure RBACで制限します。
参照先のログイン、広いContributor権限、権限不足時の再試行をそのまま実行しません。Azure CLI・azd・MCPを使う場合も接続主体の照合が必要です。
診断に必要なStorageや監視ログの読み取り権限は、初期ロールに含まれていない場合があります。

Microsoft製スキルはこのリポジトリへ複製・同梱しません。別PCで未導入でも基本一覧は使え、詳細はMicrosoft Learnで補います。
デプロイ関連スキルの参照は、対象サービス・方式・準備済み計画などの前提が合う依頼に限ります。調査依頼から自動デプロイへ進めません。

## GitHub と復元

- [機密情報・権限の扱い](docs/security.md)
- [別PCへの復元と証明書更新](docs/recovery.md)
- [各スキルが使う変更・Sandbox試験の手順](docs/change-workflow.md)

このリポジトリに、実際の接続プロファイル、証明書、Azure取得結果は保存しません。
TenantId / ApplicationId / SubscriptionId / 証明書の拇印は認証用の秘密ではありませんが、実際の値はPC側に分離しています。

## 確認状況

PowerShell構文、権限範囲、サブスクリプション選択、秘密値の出力防止、ロール定義形式と途中状態の再開条件のオフライン検証を実施しました。
共通配置済みの3スキルを確認しています。Microsoft製スキルの参照条件を追加し、リポジトリ版と配置版の一致を確認しました。
Codex付属のPython形式検証器は利用可能なPython実体を確認できていないため未実行です。スキルのname/descriptionなどの形式はPowerShellで検査しています。
Microsoft製スキルとの連携は参照条件・対象サービス・実行前の制約をレビュー済みですが、連携を使ったAzure操作の動作確認は未実施です。
初期設定でロール作成が失敗した場合の再開方法は [Azureの準備](docs/setup.md) に記載しています。
2026-11-06のユーザー提供出力で、初期設定のロール作成・割り当て完了を確認しました。
同日15:28（JST）のSandbox確認では、専用アプリの証明書認証を使うヘルパーがAppService / Functions / LogicAppsのすべてでComplete=true、Count=0を返しました。
これはユーザーが実行した結果であり、Codexが独立してAzureを取得した結果ではありません。
実リソースがある場合の表示、本番での読み取り、変更・新規作成、別PCへの復元は未検証です。
読み取りヘルパーはリソース一覧と基本メタデータを返します。全設定・実行履歴・コード取得を検証済みとは扱いません。
未対応の詳細は、サービス別スキルが公式APIと必要権限を確認し、秘密情報を出力しない取得方法を準備します。

## 公式根拠

- [Codex のユーザー共通スキル](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)
- [Azure RBAC の割り当て範囲](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-steps)
- [証明書によるサービスプリンシパル認証](https://learn.microsoft.com/entra/identity-platform/howto-authenticate-service-principal-powershell)
