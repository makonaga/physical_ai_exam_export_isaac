# Isaac on AWS - インストールガイド総合目次

## 概要

[physical_ai_exam](https://github.com/makonaga/physical_ai_exam) の ①学習データの生成 と ③評価 を NVIDIA Isaac Lab で行うための
EC2 環境を、AWS 上に構築する手順を説明します。②学習は今と同じ SageMaker Studio（LeRobot）で行います。

セキュリティの構成は [weaviate_on_aws](https://github.com/makonaga/weaviate_on_aws) と同じ考え方にしています。

- EC2 はプライベートサブネットに置き、パブリック IP は付けない（すべてのサブネットでパブリック IP の自動割り当ては無効）
- インバウンドは 0.0.0.0/0 からは禁止。必要なセキュリティグループからだけ許可する
- EC2 への接続は SSM Session Manager で行う
- IAM ポリシーは使う S3 バケットだけに絞る

## システムアーキテクチャ

```
+-----------------------------------------------------------------------------+
|                      VPC isaac-oregon-vpc (172.29.0.0/16)                   |
|                                                                             |
|  +-------------------------------+   +-------------------------------+      |
|  | Public Subnet 1 (us-west-2a)  |   | Public Subnet 2 (us-west-2c)  |      |
|  | 172.29.0.0/20                 |   | 172.29.16.0/20                |      |
|  |  +-------------------------+  |   |                               |      |
|  |  | NAT Gateway             |  |   |                               |      |
|  |  +-------------------------+  |   |                               |      |
|  +-------------------------------+   +-------------------------------+      |
|                                                                             |
|  Private Subnets（4 つ。g6e.2xlarge の空きがある AZ で起動するため）        |
|    1 (us-west-2a) 172.29.128.0/20    2 (us-west-2c) 172.29.144.0/20         |
|    3 (us-west-2b) 172.29.160.0/20    4 (us-west-2d) 172.29.176.0/20         |
|                                                                             |
|  +---------------------------+  SSH(22)  +-----------------------------+    |
|  | Isaac EC2 (g6e.2xlarge)   |<----------| SageMaker Studio（予定）    |    |
|  | NVIDIA L40S 48GB          |           | VpcOnly                     |    |
|  +-------------+-------------+           +--------------+--------------+    |
|                |                                        |                   |
|  +-------------v----------------------------------------v--------------+    |
|  | VPC Endpoints: S3 (Gateway) | CloudWatch Logs | SageMaker API/Runtime |  |
|  +---------------------------------------------------------------------+    |
+-----------------------------------------------------------------------------+
                 |                                        |
          +------v------+                          +------v------+
          | S3 Bucket   |  データ・モデルの受け渡し  | Internet    |
          | isaac-data-*|                          | (NAT 経由)  |
          +-------------+                          +-------------+
```

## 構築手順

| No. | ガイド | 説明 | 状態 |
|-----|--------|------|------|
| 01 | [VPC セットアップ](./01_vpc_setup.md) | 事前確認、VPC、サブネット、NAT Gateway、ルートテーブル、VPC エンドポイント | 検証済み |
| 02 | [セキュリティグループ](./02_security_groups.md) | Isaac EC2 用・SageMaker Studio 用のセキュリティグループ | 検証済み |
| 03 | [S3 バケットと IAM](./03_iam_policies.md) | データ受け渡し用の S3 バケット、EC2 用・Studio 用の IAM ロール | 検証済み |
| 04 | [EC2 デプロイ](./04_ec2_deployment.md) | キーペア、EC2 の起動、SSM での接続確認 | 検証済み |
| 05 | SageMaker Studio セットアップ | 同じ VPC 内の Studio ドメイン、Studio から EC2 への SSH | 未実施 |
| 06 | Isaac の導入 | EC2 への Isaac Sim 5.1・Isaac Lab 2.3・LeIsaac の導入と動作確認 | 未実施 |

## 環境情報

### リージョン

- **us-west-2**（オレゴン）。SageMaker Studio も同じリージョンに置きます。

### 主要リソース

| リソース | 名前 | 説明 |
|----------|------|------|
| VPC | isaac-oregon-vpc | 172.29.0.0/16 |
| Isaac EC2 | isaac-server | g6e.2xlarge（プライベートサブネット） |
| セキュリティグループ | isaac-oregon-isaac-sg | Isaac EC2 用 |
| セキュリティグループ | isaac-oregon-sagemaker-sg | SageMaker Studio 用 |
| セキュリティグループ | isaac-oregon-vpce-sg | VPC エンドポイント用 |
| S3 バケット | isaac-data-{AccountID} | EC2 と Studio のデータ受け渡し |
| IAM ロール | isaac-ec2-role（インスタンスプロファイル isaac-ec2-profile） | EC2 用 |
| IAM ロール | isaac-sagemaker-execution-role | SageMaker Studio 用 |
| キーペア | isaac-key | Studio から EC2 への SSH 用 |

作成したリソースの ID は、各手順の最後で `~/isaac-oregon-vpc-info.txt` に追記していきます。
ターミナルを開き直したときは、次で読み込めます。

```bash
source ~/isaac-oregon-vpc-info.txt && export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2
```

## 前提条件

- AWS CLI v2（認証設定済み。VPC・IAM・EC2・S3・SageMaker を作成できる権限）
- Session Manager Plugin（導入手順は [04_ec2_deployment.md](./04_ec2_deployment.md)）

コマンドは、とくに断りがなければ**ローカル PC のターミナル**（macOS の zsh で検証）で実行します。

## 停止と再開（コスト削減）

使わないときは EC2 を停止します。

```bash
ISAAC_INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=isaac-server" "Name=instance-state-name,Values=running,stopped" --query 'Reservations[0].Instances[0].InstanceId' --output text) && echo "Instance: $ISAAC_INSTANCE_ID"
```

```bash
aws ec2 stop-instances --instance-ids $ISAAC_INSTANCE_ID && aws ec2 wait instance-stopped --instance-ids $ISAAC_INSTANCE_ID && echo "停止しました"
```

再開するとき:

```bash
aws ec2 start-instances --instance-ids $ISAAC_INSTANCE_ID && aws ec2 wait instance-running --instance-ids $ISAAC_INSTANCE_ID && echo "起動しました"
```

- 停止した EC2 は、同じ AZ で起動し直されます。g6e は空きが少ないことがあり、`InsufficientInstanceCapacity` で
  起動できない場合は、時間をおいてやり直してください。
- EC2 を停止しても、EBS（200GB）、NAT Gateway、インターフェース型の VPC エンドポイント、NAT Gateway のパブリック IP は
  課金が続きます。
