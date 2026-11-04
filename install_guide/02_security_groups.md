# Isaac on AWS - セキュリティグループ構成ガイド

このドキュメントでは、Isaac EC2 用と SageMaker Studio 用のセキュリティグループを作成する手順を説明します。
VPC エンドポイント用のセキュリティグループは [01_vpc_setup.md](./01_vpc_setup.md) のステップ7で作成済みです。

## 事前準備

[01_vpc_setup.md](./01_vpc_setup.md) と同じターミナルで続けるか、開き直した場合は VPC 情報を読み込みます。

```bash
source ~/isaac-oregon-vpc-info.txt && export AWS_DEFAULT_REGION=us-west-2 AWS_REGION=us-west-2 && echo "VPC_ID: $VPC_ID"
```

---

## セキュリティグループ設計概要

weaviate_on_aws と同じく、インバウンドは 0.0.0.0/0 からは禁止し、必要なセキュリティグループからだけ許可します。
VPC のデフォルトのセキュリティグループ（`default`）は使いません。

| セキュリティグループ | 用途 | インバウンド |
|---------------------|------|-------------|
| isaac-oregon-isaac-sg | Isaac EC2 | TCP 22（SSH）: SageMaker Studio SG から |
| isaac-oregon-sagemaker-sg | SageMaker Studio | All: 自己参照（Studio 内部通信。weaviate の `06_sagemaker_studio_setup.md` と同じ） |
| isaac-oregon-vpce-sg | VPC エンドポイント | TCP 443: VPC の CIDR（172.29.0.0/16）から |

### トラフィックフロー

```
+--------------------+
|  SageMaker Studio  |--> S3 / SageMaker API (VPC Endpoint)
+---------+----------+
          | SSH (22)
          v
+--------------------+
|  Isaac EC2         |--> S3 (VPC Endpoint), Internet (NAT Gateway)
+--------------------+
```

---

## ステップ1: SageMaker Studio用セキュリティグループの作成

```bash
SAGEMAKER_SG_ID=$(aws ec2 create-security-group --group-name isaac-oregon-sagemaker-sg --description "Security group for SageMaker Studio - Isaac on AWS" --vpc-id $VPC_ID --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=isaac-oregon-sagemaker-sg},{Key=Project,Value=IsaacOnAWS}]' --query 'GroupId' --output text) && echo "SageMaker SG: $SAGEMAKER_SG_ID"
```

自己参照ルール（SageMaker Studio 内部通信用）を追加します。

```bash
aws ec2 authorize-security-group-ingress --group-id $SAGEMAKER_SG_ID --protocol -1 --source-group $SAGEMAKER_SG_ID
```

---

## ステップ2: Isaac EC2用セキュリティグループの作成

```bash
ISAAC_SG_ID=$(aws ec2 create-security-group --group-name isaac-oregon-isaac-sg --description "Security group for Isaac EC2 - Isaac on AWS" --vpc-id $VPC_ID --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=isaac-oregon-isaac-sg},{Key=Project,Value=IsaacOnAWS}]' --query 'GroupId' --output text) && echo "Isaac SG: $ISAAC_SG_ID"
```

SageMaker Studio からの SSH（ポート 22）を許可します。

```bash
aws ec2 authorize-security-group-ingress --group-id $ISAAC_SG_ID --protocol tcp --port 22 --source-group $SAGEMAKER_SG_ID
```

---

## ステップ3: セキュリティグループの確認

VPC 内のセキュリティグループと、それぞれのインバウンドのルールを表示します。

```bash
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[*].{Name:GroupName,Id:GroupId,Inbound:IpPermissions[*].{Proto:IpProtocol,From:FromPort,To:ToPort,Cidr:IpRanges[*].CidrIp,SG:UserIdGroupPairs[*].GroupId}}' --output json
```

`default` は VPC 作成時に自動でできるセキュリティグループで、この構成ではどこにも使いません。

**セキュリティポリシー**: 0.0.0.0/0 からのインバウンドがないことを確認します。`[[], [], [], []]` のように中身がすべて空であれば OK です。

```bash
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[*].IpPermissions[?contains(IpRanges[*].CidrIp, `0.0.0.0/0`)]' --output json
```

---

## ステップ4: セキュリティグループ情報の保存

```bash
cat >> ~/isaac-oregon-vpc-info.txt << EOF
SAGEMAKER_SG_ID=$SAGEMAKER_SG_ID
ISAAC_SG_ID=$ISAAC_SG_ID
EOF
```

---

## セキュリティグループ構成サマリー

### isaac-oregon-isaac-sg (Isaac EC2)

| 方向 | プロトコル | ポート | ソース/宛先 | 説明 |
|------|-----------|--------|-------------|------|
| インバウンド | TCP | 22 | SageMaker SG | SSH（SageMaker Studio から） |
| アウトバウンド | All | All | 0.0.0.0/0 | デフォルト |

### isaac-oregon-sagemaker-sg (SageMaker Studio)

| 方向 | プロトコル | ポート | ソース/宛先 | 説明 |
|------|-----------|--------|-------------|------|
| インバウンド | All | All | 自己参照 | SageMaker 内部通信 |
| アウトバウンド | All | All | 0.0.0.0/0 | デフォルト |

### isaac-oregon-vpce-sg (VPC エンドポイント)

| 方向 | プロトコル | ポート | ソース/宛先 | 説明 |
|------|-----------|--------|-------------|------|
| インバウンド | TCP | 443 | 172.29.0.0/16 | VPC 内からの HTTPS |
| アウトバウンド | All | All | 0.0.0.0/0 | デフォルト |

---

## 次のステップ

[03_iam_policies.md](./03_iam_policies.md) に進み、S3 バケットと IAM ロールを作成します。
